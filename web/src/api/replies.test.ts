import { ReplyBus, isFinal } from "./replies";
import type { Reply } from "./types";

const reply = (id: string, status: Reply["status"] = "done"): Reply => ({ id, status, reason: null, at: "x" });

afterEach(() => vi.useRealTimers());

it("treats accepted as not final", () => {
  expect(isFinal(reply("a", "accepted"))).toBe(false);
  expect(isFinal(reply("a", "refused"))).toBe(true);
});

it("resolves a waiter when its reply arrives", async () => {
  const bus = new ReplyBus();
  const waiting = bus.wait("a", 1000);
  bus.deliver(reply("a", "accepted"));
  bus.deliver(reply("a"));
  await expect(waiting).resolves.toEqual(reply("a"));
});

it("keeps a reply that beat its waiter", async () => {
  const bus = new ReplyBus();
  bus.deliver(reply("b", "refused"));
  await expect(bus.wait("b", 1000)).resolves.toEqual(reply("b", "refused"));
});

it("drops the oldest early replies past its limit", async () => {
  vi.useFakeTimers();
  const bus = new ReplyBus();
  for (let i = 0; i <= 200; i++) bus.deliver(reply(`r${i}`));
  const old = bus.wait("r0", 10);
  vi.advanceTimersByTime(20);
  await expect(old).rejects.toThrow("No reply to command r0");
  await expect(bus.wait("r200", 10)).resolves.toEqual(reply("r200"));
});

it("rejects after the timeout", async () => {
  vi.useFakeTimers();
  const bus = new ReplyBus();
  const waiting = bus.wait("c", 2000);
  vi.advanceTimersByTime(2000);
  await expect(waiting).rejects.toThrow("within 2s");
});

it("forget and clear stop the timers", () => {
  vi.useFakeTimers();
  const bus = new ReplyBus();
  void bus.wait("d", 100);
  void bus.wait("e", 100);
  bus.forget("d");
  bus.forget("missing");
  bus.clear();
  expect(vi.getTimerCount()).toBe(0);
});
