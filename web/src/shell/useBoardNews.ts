import { useEffect, useRef } from "react";
import type { Snapshot } from "../api/types";
import { planId } from "../board/format";

/**
 * What changed between two snapshots that is news: a plan advancing, an approval, a merge. Counters are not news
 * (design.md, "Live is not loud"), so they are never announced.
 */
export function boardNews(before: Snapshot | undefined, after: Snapshot): string[] {
  if (!before) return [];
  const was = new Map(before.plans.map(p => [p.ordinal, p]));
  const news: string[] = [];
  for (const plan of after.plans) {
    const prev = was.get(plan.ordinal);
    if (!prev) continue;
    const id = planId(plan.ordinal);
    const pr = plan.pr;
    if (pr && pr.state !== prev.pr?.state && pr.state === "merged") news.push(`PR #${pr.number} was merged on GitHub. ${id} is complete.`);
    else if (pr && pr.state !== prev.pr?.state && pr.state === "approved") news.push(`${id} was approved and is ready to merge.`);
    else if (plan.station !== prev.station) {
      const label = after.stations.find(s => s.key === plan.station)?.label ?? plan.station;
      news.push(`${id} moved to ${label}.`);
    }
  }
  return news;
}

/** Announces each snapshot's news through the page's live region. */
export function useBoardNews(snapshot: Snapshot | undefined, announce: (text: string) => void): void {
  const last = useRef<Snapshot | undefined>(undefined);
  useEffect(() => {
    if (!snapshot) return;
    const news = boardNews(last.current, snapshot);
    last.current = snapshot;
    if (news.length) announce(news.join(" "));
  }, [snapshot, announce]);
}
