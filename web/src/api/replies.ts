// Replies arrive on the event stream, not on the POST that sent their command, so a sender waits here for its id.
// A reply can beat its waiter (the engine is fast, the 202 is slow), so finished replies are kept for a while.
import type { Reply } from "./types";

const KEPT = 200;

/** `accepted` only says the command is queued; `done` and `refused` are what a sender waits for. */
export const isFinal = (reply: Reply): boolean => reply.status !== "accepted";

export class ReplyBus {
  private waiters = new Map<string, { settle: (reply: Reply) => void; timer: ReturnType<typeof setTimeout> }>();
  private early = new Map<string, Reply>();

  deliver(reply: Reply): void {
    if (!isFinal(reply)) return;
    const waiter = this.waiters.get(reply.id);
    if (waiter) {
      this.waiters.delete(reply.id);
      clearTimeout(waiter.timer);
      waiter.settle(reply);
      return;
    }
    this.early.set(reply.id, reply);
    if (this.early.size > KEPT) this.early.delete(this.early.keys().next().value as string);
  }

  /** Resolves with the command's final reply, or rejects once `timeoutMs` passes without one. */
  wait(id: string, timeoutMs: number): Promise<Reply> {
    const ready = this.early.get(id);
    if (ready) {
      this.early.delete(id);
      return Promise.resolve(ready);
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters.delete(id);
        reject(new Error(`No reply to command ${id} within ${Math.round(timeoutMs / 1000)}s`));
      }, timeoutMs);
      this.waiters.set(id, { settle: resolve, timer });
    });
  }

  /** Stops waiting for `id`: the POST failed or was refused, so no reply is coming. Its promise stays pending. */
  forget(id: string): void {
    const waiter = this.waiters.get(id);
    if (waiter) clearTimeout(waiter.timer);
    this.waiters.delete(id);
  }

  clear(): void {
    for (const waiter of this.waiters.values()) clearTimeout(waiter.timer);
    this.waiters.clear();
    this.early.clear();
  }
}

/** The page's one bus: useBoard feeds it from the stream, useSendCommand waits on it. */
export const replies = new ReplyBus();
