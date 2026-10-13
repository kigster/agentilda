import type { Board } from "../api/types";
import { planId, who } from "../board/format";
import { isMerged } from "../board/model";

/** "Not listed: 001, 002 in this run; 008 on alex@build-01; 011 complete." under the Action menu's plan list. */
export function backlogNote(board: Board): string | undefined {
  const mine = board.me.plans.filter(p => !isMerged(p)).map(p => planId(p.ordinal));
  const busy = board.others.flatMap(o => o.plans.filter(p => !isMerged(p)).map(p => `${planId(p.ordinal)} on ${who(o.node)}`));
  const complete = [board.me, ...board.others].flatMap(s => s.plans.filter(isMerged).map(p => planId(p.ordinal)));
  const parts = [mine.length ? `${mine.join(", ")} in this run` : "", busy.join(", "), complete.length ? `${complete.join(", ")} complete` : ""];
  const said = parts.filter(Boolean);
  return said.length ? `Not listed: ${said.join("; ")}.` : undefined;
}
