// Every command answers: accepted, refused with a reason, or done. This is where a panel hears that, says it to screen
// readers through the page's announcer, and keeps it to show in place.
import { createContext, useCallback, useContext, useMemo, useRef, useState } from "react";
import type { Command, Reply } from "../api/types";
import type { SendCommand } from "./support";

type Announce = (text: string) => void;
export const AnnouncerContext = createContext<Announce | null>(null);

/** Says something to screen readers, or nothing when no announcer is mounted. */
export function useAnnounce(): { announce: Announce; mounted: boolean } {
  const ctx = useContext(AnnouncerContext);
  return { announce: ctx ?? (() => {}), mounted: ctx !== null };
}

export interface Outcome {
  tone: "ok" | "refused";
  text: string;
}

/** What a refusal says: the engine's reason, or that it gave none. */
export const refusal = (reply: Reply): string => `Refused: ${reply.reason ?? "no reason given"}.`;

/**
 * Sends a command and keeps its outcome. A rejected promise (the network, a 5xx) reads as a refusal, so nothing fails
 * silently. `say` is the sentence an accepted or done reply shows, or a function of the reply when the two differ.
 * One command at a time: a second send while one is in flight (a repeated ⌘ Enter) is a no-op that resolves to null,
 * because each send would otherwise mint its own id and the engine would act twice.
 */
export function useCommand(onCommand: SendCommand) {
  const { announce, mounted } = useAnnounce();
  const [outcome, setOutcome] = useState<Outcome | null>(null);
  const [pending, setPending] = useState(false);
  const inFlight = useRef(false);
  const send = useCallback(
    async (command: Omit<Command, "id">, say: string | ((reply: Reply) => string)): Promise<Reply | null> => {
      if (inFlight.current) return null;
      inFlight.current = true;
      setPending(true);
      let reply: Reply;
      try {
        reply = await onCommand(command);
      } catch (error) {
        reply = { id: "", status: "refused", reason: error instanceof Error ? error.message : String(error), at: new Date().toISOString() };
      }
      inFlight.current = false;
      const next: Outcome = reply.status === "refused" ? { tone: "refused", text: refusal(reply) } : { tone: "ok", text: typeof say === "string" ? say : say(reply) };
      setOutcome(next);
      setPending(false);
      announce(next.text);
      return reply;
    },
    [onCommand, announce],
  );
  return useMemo(() => ({ send, outcome, pending, setOutcome, announced: mounted }), [send, outcome, pending, mounted]);
}

