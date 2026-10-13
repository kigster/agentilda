// Lines the person added to a drawer's transcript before the snapshot carries them.

/** One optimistic line, and how many copies of it the history already held, or were already pending, when it was added. */
export interface Pending {
  text: string;
  base: number;
}

const count = (lines: string[], text: string) => lines.reduce((n, l) => (l === text ? n + 1 : n), 0);

/** Adds a line, newest first. Its base counts the copies that are not it, so a repeat waits for its own arrival. */
export function pend(pending: Pending[], history: string[], text: string): Pending[] {
  return [{ text, base: count(history, text) + count(pending.map((p) => p.text), text) }, ...pending];
}

/**
 * The lines the history does not hold yet. A line is in once its text appears in the history more often than its
 * base, so each arrival answers for exactly one line and saying the same thing twice shows twice until both land.
 */
export function unconfirmed(pending: Pending[], history: string[]): Pending[] {
  return pending.filter((p) => count(history, p.text) <= p.base);
}
