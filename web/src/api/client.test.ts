import { ApiError, fetchBoard, getSession, isFixtureMode, loadFixtureBoard, mintCommand, postCommand, resetSession } from "./client";
import type { Command } from "./types";

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const session = { csrf: "tok-1", node: {}, repo: "github.com/example-org/example-repo" };
const command: Command = { id: "01J0000000000000000000000", kind: "hold", plan: "001.00", agent: "luke-backend", payload: {} };

let fetchMock: ReturnType<typeof vi.fn>;
beforeEach(() => {
  resetSession();
  fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);
});
afterEach(() => vi.unstubAllGlobals());

describe("isFixtureMode", () => {
  it("is on with ?fixture and off without it", () => {
    expect(isFixtureMode("?fixture")).toBe(true);
    expect(isFixtureMode("?x=1&fixture=1")).toBe(true);
    expect(isFixtureMode("")).toBe(false);
  });

  it("reads the page's own URL by default", () => {
    expect(isFixtureMode()).toBe(false);
  });
});

describe("loadFixtureBoard", () => {
  it("hands out a fresh copy every time", () => {
    const a = loadFixtureBoard();
    a.me.plans.length = 0;
    expect(loadFixtureBoard().me.plans.length).toBeGreaterThan(0);
  });
});

describe("fetchBoard", () => {
  it("returns the board", async () => {
    fetchMock.mockResolvedValue(json(200, { me: 1 }));
    await expect(fetchBoard()).resolves.toEqual({ me: 1 });
    expect(fetchMock).toHaveBeenCalledWith("/api/board", expect.objectContaining({ credentials: "same-origin" }));
  });

  it("throws an ApiError carrying the status", async () => {
    fetchMock.mockResolvedValue(json(503, {}));
    await expect(fetchBoard()).rejects.toMatchObject({ name: "ApiError", status: 503 });
  });
});

describe("getSession", () => {
  it("fetches once and caches", async () => {
    fetchMock.mockResolvedValue(json(200, session));
    await getSession();
    await getSession();
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("forgets a failed fetch so the next call tries again", async () => {
    fetchMock.mockResolvedValueOnce(json(500, {})).mockResolvedValueOnce(json(200, session));
    await expect(getSession()).rejects.toBeInstanceOf(ApiError);
    await expect(getSession()).resolves.toEqual(session);
  });
});

describe("mintCommand", () => {
  it("adds a ULID", () => {
    const { id, ...rest } = mintCommand({ kind: "stop_all", plan: null, agent: null, payload: {} });
    expect(id).toMatch(/^[0-9A-HJKMNP-TV-Z]{26}$/);
    expect(rest.kind).toBe("stop_all");
  });
});

describe("postCommand", () => {
  it("sends the token and returns the accepted reply", async () => {
    const reply = { id: command.id, status: "accepted", reason: null, at: "x" };
    fetchMock.mockResolvedValueOnce(json(200, session)).mockResolvedValueOnce(json(202, reply));
    await expect(postCommand(command)).resolves.toEqual(reply);
    const [path, init] = fetchMock.mock.calls[1];
    expect(path).toBe("/api/commands");
    expect(init.headers["X-CSRF-Token"]).toBe("tok-1");
    expect(JSON.parse(init.body)).toEqual(command);
  });

  it("returns a refusal", async () => {
    const reply = { id: command.id, status: "refused", reason: "no such plan", at: "x" };
    fetchMock.mockResolvedValueOnce(json(200, session)).mockResolvedValueOnce(json(422, reply));
    await expect(postCommand(command)).resolves.toEqual(reply);
  });

  it("refreshes a stale token once and resends the same command", async () => {
    const reply = { id: command.id, status: "accepted", reason: null, at: "x" };
    fetchMock
      .mockResolvedValueOnce(json(200, session))
      .mockResolvedValueOnce(json(403, {}))
      .mockResolvedValueOnce(json(200, { ...session, csrf: "tok-2" }))
      .mockResolvedValueOnce(json(202, reply));
    await expect(postCommand(command)).resolves.toEqual(reply);
    expect(fetchMock.mock.calls[3][1].headers["X-CSRF-Token"]).toBe("tok-2");
    expect(JSON.parse(fetchMock.mock.calls[3][1].body).id).toBe(command.id);
  });

  it("throws on anything else", async () => {
    fetchMock.mockResolvedValueOnce(json(200, session)).mockResolvedValueOnce(json(500, {}));
    await expect(postCommand(command)).rejects.toMatchObject({ status: 500 });
  });
});
