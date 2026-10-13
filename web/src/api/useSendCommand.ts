import { useMutation } from "@tanstack/react-query";
import type { Reply } from "./types";
import { isFixtureMode, mintCommand, postCommand, type CommandInput } from "./client";
import { replies } from "./replies";

/** How long a sender waits for the engine's reply before giving up. The engine reads commands every tick. */
export const REPLY_TIMEOUT_MS = 60_000;

/**
 * Sends one command and resolves with its final reply: `done`, or `refused` (by the API server's validation or by
 * the engine). A network failure or a missing reply rejects. Under `?fixture` it answers `done` at once.
 */
export async function sendCommand(input: CommandInput, timeoutMs = REPLY_TIMEOUT_MS): Promise<Reply> {
  const command = mintCommand(input);
  if (isFixtureMode()) return { id: command.id, status: "done", reason: null, at: new Date().toISOString() };
  // Wait first: the reply can arrive on the stream before the POST's own response does.
  const reply = replies.wait(command.id, timeoutMs);
  try {
    const first = await postCommand(command);
    if (first.status === "refused") {
      replies.forget(command.id);
      return first;
    }
  } catch (error) {
    replies.forget(command.id);
    throw error;
  }
  return reply;
}

export function useSendCommand() {
  return useMutation<Reply, Error, CommandInput>({ mutationFn: input => sendCommand(input) });
}
