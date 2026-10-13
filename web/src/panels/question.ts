// A request's actions, shared by the rail's card, the unblock widget and the drawer's question block.
import { useState } from "react";
import type { Plan, Question } from "../api/types";
import { useAsk } from "./asks";
import { useCommand } from "./command";
import { questionRef, type SendCommand } from "./support";

export type Ask =
  | { kind: "question"; id: string; plan: Plan; question: Question }
  | { kind: "interrupt"; id: string; plan: Plan; interrupted: NonNullable<Plan["interrupted"]> };

/** Every request in these plans, questions first within a plan, held ones included. */
export function asksOf(plans: Plan[]): Ask[] {
  return plans.flatMap((plan) => [
    ...plan.questions.map((question): Ask => ({ kind: "question", id: question.id, plan, question })),
    ...(plan.interrupted ? [{ kind: "interrupt", id: `${plan.ordinal}/interrupt`, plan, interrupted: plan.interrupted } as Ask] : []),
  ]);
}

const who = (q: Question) => q.agent ?? "the agent";

/** The question's actions, for the card and for the drawer's question block. */
export function useQuestion(plan: Plan, question: Question, onCommand: SendCommand, onAnswered?: (text: string) => void) {
  const [state, update] = useAsk(question.id);
  const command = useCommand(onCommand);
  const [invalid, setInvalid] = useState(false);
  const [held, setHeld] = useState<boolean | null>(null);
  const base = { plan: plan.ordinal, agent: question.agent };

  const settle = async (text: string, note: string) => {
    const reply = await command.send({ ...base, kind: "answer", payload: { question: questionRef(question), text } }, note);
    if (reply.status !== "refused") {
      update({ settled: note, draft: "" });
      onAnswered?.(text);
    }
    return reply;
  };
  /** An answer needs words: an empty one would unblock the agent with nothing to go on. */
  const answer = async () => {
    const text = state.draft.trim();
    if (!text) { setInvalid(true); return false; }
    await settle(text, `Answer sent to ${who(question)}.`);
    return true;
  };
  const choose = (word: string) => settle(word, `Answered ${word.toLowerCase()} to ${who(question)}.`);
  const isHeld = held ?? question.held;
  const toggleHold = async () => {
    const holding = !isHeld;
    const reply = await command.send(
      { ...base, kind: holding ? "hold_blocked" : "release_hold", payload: { question: questionRef(question) } },
      holding ? `${plan.ordinal} held blocked. Its red pill in the status bar brings it back.` : `${plan.ordinal} no longer held.`,
    );
    if (reply.status !== "refused") setHeld(holding);
    return reply.status !== "refused" && holding;
  };
  return {
    state, update, command, invalid, isHeld, answer, choose, toggleHold,
    setDraft: (draft: string) => { setInvalid(false); update({ draft }); },
    yesNo: Boolean(question.answers?.length) && !state.inWords,
  };
}
