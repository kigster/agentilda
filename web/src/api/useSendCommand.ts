import { useMutation } from "@tanstack/react-query";
import type { Reply } from "./types";
import { ApiError, getSession, isFixtureMode, mintCommand, postCommand, type CommandInput } from "./client";
import { replies } from "./replies";

/** How long a sender waits for the engine's reply before giving up. The engine reads commands every tick. */
export const REPLY_TIMEOUT_MS = 60_000;

/**
 * Sends one command and resolves with its final reply: `done`, or `refused` (by the API server's validation or by
 * the engine). Under `?fixture` it answers `done` at once.
 *
 * It fails fast only when the command certainly did not land: the session could not be fetched before sending, or the
 * server answered with an HTTP error. A transport failure after sending (a dropped connection, an abort) is ambiguous:
 * the server may have queued it, so it keeps waiting for the reply by the same id, up to the timeout. The id is minted
 * once per intent and never again.
 */
export async function sendCommand(input: CommandInput, timeoutMs = REPLY_TIMEOUT_MS): Promise<Reply> {
  const command = mintCommand(input);
  if (isFixtureMode()) return { id: command.id, status: "done", reason: null, at: new Date().toISOString() };
  await getSession(); // a failure here is before submission: nothing was sent
  // Wait first: the reply can arrive on the stream before the POST's own response does.
  const reply = replies.wait(command.id, timeoutMs);
  try {
    const first = await postCommand(command);
    if (first.status === "refused") {
      replies.forget(command.id);
      return first;
    }
  } catch (error) {
    if (error instanceof ApiError) {
      replies.forget(command.id);
      throw error;
    }
    // Ambiguous: it may have reached the server. Its reply, if any, arrives on the stream.
  }
  return reply;
}

export function useSendCommand() {
  return useMutation<Reply, Error, CommandInput>({ mutationFn: input => sendCommand(input) });
}
