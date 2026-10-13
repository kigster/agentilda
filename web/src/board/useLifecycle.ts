import { useCallback, useEffect, useRef, useState } from "react";
import type { Plan } from "../api/types";
import { isFinished, isMerged } from "./model";

/** A merged row stays this long, purple, before it fades. */
export const ROW_STAYS_MS = 10_000;
/** …and fades and folds away over this long. */
export const FADE_MS = 1_000;
/** A purple pill leaves an overflowing bar only after this long (the mockup's 30 s stands in for five minutes). */
export const MERGED_STAYS_MS = 5 * 60_000;

export interface GonePlan {
  plan: Plan;
  /** Date.now() when its row left the board. */
  at: number;
}

export interface Lifecycle {
  /** Rows fading out right now. */
  retiring: ReadonlySet<string>;
  /** Merged plans whose rows have left the board, still shown as purple pills. */
  gone: ReadonlyMap<string, GonePlan>;
  /** The order plans finished in, for the right-hand end of the status bar. */
  finishOrder: ReadonlyMap<string, number>;
  /** Purple pills taken off an overflowing bar; their plans stay gone from the board. */
  offBar: ReadonlySet<string>;
  /** Takes a purple pill off the bar for good. */
  dropFromBar(ordinal: string): void;
}

const without = <T,>(set: ReadonlySet<T>, item: T): Set<T> => {
  const next = new Set(set);
  next.delete(item);
  return next;
};

/**
 * The page's memory of what the snapshot no longer says: when each merged row should fade, which merged plans have
 * already left the board, and the order plans finished in. Timers live here, not in the board, so switching tabs
 * never restarts a merged row's ten seconds.
 *
 * Keyed by ordinal. For other machines, App passes their plans with the ordinal replaced by nodePlanKey, so one hook
 * tracks every machine without two machines' 010.00 colliding.
 */
export function useLifecycle(plans: Plan[], reduced = false): Lifecycle {
  const [retiring, setRetiring] = useState<ReadonlySet<string>>(new Set());
  const [gone, setGone] = useState<ReadonlyMap<string, GonePlan>>(new Map());
  const [finishOrder, setFinishOrder] = useState<ReadonlyMap<string, number>>(new Map());
  const [offBar, setOffBar] = useState<ReadonlySet<string>>(new Set());
  const timers = useRef(new Map<string, ReturnType<typeof setTimeout>>());
  const merged = useRef(new Map<string, Plan>());

  const leave = useCallback((plan: Plan) => {
    const k = plan.ordinal;
    setRetiring(prev => (prev.has(k) ? without(prev, k) : prev));
    setGone(prev => (prev.has(k) ? prev : new Map(prev).set(k, { plan, at: Date.now() })));
  }, []);

  useEffect(() => {
    const k = (p: Plan) => p.ordinal;
    const live = new Set(plans.map(k));
    // A merged plan the engine already dropped has left the board, whatever its timer says.
    for (const [ordinal, plan] of merged.current) {
      if (live.has(ordinal)) continue;
      clearTimeout(timers.current.get(ordinal));
      merged.current.delete(ordinal);
      leave(plan);
    }
    for (const plan of plans) {
      const id = k(plan);
      if (!isMerged(plan) || merged.current.has(id)) continue;
      merged.current.set(id, plan);
      timers.current.set(id, setTimeout(() => {
        setRetiring(prev => new Set(prev).add(id));
        timers.current.set(id, setTimeout(() => leave(plan), reduced ? 0 : FADE_MS));
      }, ROW_STAYS_MS));
    }
    setFinishOrder(prev => {
      const fresh = plans.filter(p => isFinished(p) && !prev.has(k(p))).map(k).sort();
      if (!fresh.length) return prev;
      const next = new Map(prev);
      for (const id of fresh) next.set(id, next.size + 1);
      return next;
    });
  }, [plans, leave, reduced]);

  useEffect(() => {
    const pending = timers.current;
    const seen = merged.current;
    return () => {
      // Forget them too, so a remount (StrictMode does one) schedules the timers again rather than never.
      for (const t of pending.values()) clearTimeout(t);
      pending.clear();
      seen.clear();
    };
  }, []);

  const dropFromBar = useCallback((ordinal: string) => {
    setOffBar(prev => (prev.has(ordinal) ? prev : new Set(prev).add(ordinal)));
  }, []);

  return { retiring, gone, finishOrder, offBar, dropFromBar };
}
