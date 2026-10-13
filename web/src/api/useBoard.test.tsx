import type { ReactNode } from "react";
import { QueryClientProvider } from "@tanstack/react-query";
import { act, renderHook, waitFor } from "@testing-library/react";
import { createQueryClient } from "./queryClient";
import { useBoard } from "./useBoard";
import { replies } from "./replies";
import type { StreamHandlers } from "./events";
import { loadFixtureBoard } from "./client";

const streams: StreamHandlers[] = [];
const closed = vi.fn();
vi.mock("./events", () => ({
  openStream: (h: StreamHandlers) => {
    streams.push(h);
    return closed;
  },
}));

const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={createQueryClient()}>{children}</QueryClientProvider>;
const json = (body: unknown) => new Response(JSON.stringify(body), { status: 200 });

let fetchMock: ReturnType<typeof vi.fn>;
beforeEach(() => {
  streams.length = 0;
  fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);
});
afterEach(() => {
  vi.unstubAllGlobals();
  window.history.replaceState(null, "", "/");
});

it("loads the board, follows the stream, and refetches on reconnect", async () => {
  const first = loadFixtureBoard();
  fetchMock.mockResolvedValue(json(first));
  const { result, unmount } = renderHook(() => useBoard(), { wrapper });
  expect(result.current.isLoading).toBe(true);
  expect(result.current.connection).toBe("reconnecting");
  await waitFor(() => expect(result.current.board?.me.seq).toBe(first.me.seq));
  expect(result.current.fixture).toBe(false);

  const stream = streams[0];
  const next = { ...first, me: { ...first.me, seq: 99 } };
  act(() => {
    stream.onState("live");
    stream.onBoard(next);
  });
  expect(result.current.connection).toBe("live");
  expect(result.current.board?.me.seq).toBe(99);

  const deliver = vi.spyOn(replies, "deliver");
  stream.onReply({ id: "x", status: "done", reason: null, at: "t" });
  expect(deliver).toHaveBeenCalled();

  act(() => stream.onReconnect());
  await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
  unmount();
  expect(closed).toHaveBeenCalled();
});

it("reports a failed first load", async () => {
  fetchMock.mockResolvedValue(new Response("{}", { status: 500 }));
  const client = createQueryClient();
  client.setDefaultOptions({ queries: { retry: false } });
  const { result } = renderHook(() => useBoard(), {
    wrapper: ({ children }: { children: ReactNode }) => <QueryClientProvider client={client}>{children}</QueryClientProvider>,
  });
  await waitFor(() => expect(result.current.error).toBeTruthy());
});

it("serves the fixture under ?fixture without a stream or a fetch", async () => {
  window.history.replaceState(null, "", "/?fixture");
  const { result } = renderHook(() => useBoard(), { wrapper });
  await waitFor(() => expect(result.current.board).toBeDefined());
  expect(result.current.fixture).toBe(true);
  expect(result.current.connection).toBe("live");
  expect(streams).toHaveLength(0);
  expect(fetchMock).not.toHaveBeenCalled();
});
