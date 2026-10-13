import { QueryClientProvider } from "@tanstack/react-query";
import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import App from "./App";
import type { Board, LogLine } from "./api/types";
import board from "./api/fixtures/board.json";
import { createQueryClient } from "./api/queryClient";
import type { StreamHandlers } from "./api/events";
import { sampleBoard, samplePr } from "./board/sample";

const streams: StreamHandlers[] = [];
vi.mock("./api/events", () => ({
  openStream: (h: StreamHandlers) => {
    streams.push(h);
    return () => {};
  },
}));

const renderApp = () => {
  const client = createQueryClient();
  client.setDefaultOptions({ queries: { retry: false } });
  return render(
    <QueryClientProvider client={client}>
      <App />
    </QueryClientProvider>,
  );
};
const pills = () => within(document.querySelector<HTMLElement>(".pills")!);

beforeEach(() => {
  streams.length = 0;
  localStorage.clear();
});
afterEach(() => {
  vi.unstubAllGlobals();
  window.history.replaceState(null, "", "/");
});

it("has a fixture that satisfies the Board contract", () => {
  const typed: Board = board as Board;
  expect(typed.me.plans.length).toBeGreaterThan(0);
});

describe("under ?fixture", () => {
  beforeEach(() => window.history.replaceState(null, "", "/?fixture"));

  it("draws the header, the tabs, the board and the status bar", async () => {
    renderApp();
    expect(await screen.findByText("Fixture data")).toBeInTheDocument();
    expect(screen.getByRole("tab", { name: "Board" })).toHaveAttribute("aria-selected", "true");
    expect(screen.getByRole("tab", { name: /001 tests/ })).toHaveTextContent("52 of 465");
    expect(screen.getByRole("tab", { name: "sam@ci-runner-2" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Clean agent boundaries and transitions" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /^Action/ })).toBeInTheDocument();
    expect(screen.getByText("0 merged, 0 ready to merge, 2 blocked")).toBeInTheDocument();
  });

  it("switches tabs with the arrow keys and shows the Logs and test tabs", async () => {
    const user = userEvent.setup();
    renderApp();
    const boardTab = await screen.findByRole("tab", { name: "Board" });
    act(() => boardTab.focus());
    await user.keyboard("{ArrowRight}");
    expect(screen.getByRole("tab", { name: /Logs/ })).toHaveAttribute("aria-selected", "true");
    expect(screen.getByRole("list", { name: "Log lines, newest last" })).toBeVisible();
    await user.click(screen.getByRole("tab", { name: /001 tests/ }));
    expect(screen.getByRole("heading", { name: /001 Clean agent boundaries and transitions: tests/ })).toBeInTheDocument();
  });

  it("toggles a machine tab: first its board, then every machine on the Board", async () => {
    const user = userEvent.setup();
    renderApp();
    const tab = await screen.findByRole("tab", { name: "sam@ci-runner-2" });
    await user.click(tab);
    expect(tab).toHaveAttribute("aria-selected", "true");
    expect(screen.getByText(/this machine will not start them/)).toBeInTheDocument();
    await user.click(tab);
    expect(screen.getByRole("tab", { name: "Board" })).toHaveAttribute("aria-selected", "true");
    expect(screen.getByRole("button", { name: "All machines" })).toHaveAttribute("aria-pressed", "true");
    expect(localStorage.getItem("agentilda-merged")).toBe("1");
    await waitFor(() => expect(screen.getByTestId("announcer")).toHaveTextContent("Showing every machine's plans."));
    await user.click(screen.getByRole("button", { name: "All machines" }));
    expect(screen.getByRole("button", { name: "All machines" })).toHaveAttribute("aria-pressed", "false");
    // Their pill opens their tab.
    await user.click(screen.getByTitle(/^010 .*Read only\./));
    expect(tab).toHaveAttribute("aria-selected", "true");
    // Enter on the selected machine tab is a second press.
    act(() => tab.focus());
    await user.keyboard("{Enter}");
    expect(screen.getByRole("tab", { name: "Board" })).toHaveAttribute("aria-selected", "true");
  });

  it("toggles the unblock widget from a red pill and returns focus to it", async () => {
    const user = userEvent.setup();
    renderApp();
    const pill = await screen.findByRole("button", { name: /^001, needs technical decision/ });
    await user.click(pill);
    expect(pill).toHaveAttribute("aria-expanded", "true");
    expect(screen.getByRole("region", { name: /Unblock 001/ })).toBeInTheDocument();
    await user.click(pill);
    expect(screen.queryByRole("region", { name: /Unblock 001/ })).toBeNull();
    await user.click(pill);
    await user.click(within(screen.getByRole("region", { name: /Unblock 001/ })).getByRole("button", { name: "Hide" }));
    expect(pill).toHaveFocus();
  });

  it("shows a working plan's row from its pill, and opens and closes a car's drawer", async () => {
    const user = userEvent.setup();
    renderApp();
    await user.click(await screen.findByRole("tab", { name: /Logs/ }));
    await user.click(pills().getByRole("button", { name: /^005, working/ }));
    expect(screen.getByRole("tab", { name: "Board" })).toHaveAttribute("aria-selected", "true");
    const hansolo = screen.getByRole("button", { name: "hansolo-reviewer" });
    expect(hansolo).toHaveFocus();
    await user.click(hansolo);
    expect(hansolo).toHaveAttribute("aria-expanded", "true");
    expect(screen.queryByRole("heading", { name: /Needs you/ })).toBeNull();
    await user.click(screen.getByRole("button", { name: "Close" }));
    expect(screen.getByRole("heading", { name: /Needs you/ })).toBeInTheDocument();
    expect(hansolo).toHaveFocus();
  });
});

it("opens the idea dialog when the page is loaded at #start", async () => {
  window.history.replaceState(null, "", "/?fixture#start");
  renderApp();
  expect(await screen.findByRole("dialog")).toBeInTheDocument();
});

it("works in a private window, where storage throws", async () => {
  window.history.replaceState(null, "", "/?fixture");
  const get = vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
    throw new Error("denied");
  });
  const set = vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
    throw new Error("denied");
  });
  renderApp();
  const toggle = await screen.findByRole("button", { name: "All machines" });
  await userEvent.click(toggle);
  expect(toggle).toHaveAttribute("aria-pressed", "true");
  get.mockRestore();
  set.mockRestore();
});

describe("live", () => {
  const json = (body: unknown) => new Response(JSON.stringify(body), { status: 200 });

  it("waits for the board, then follows the stream", async () => {
    const first = sampleBoard();
    first.me.plans[0].cars[0].state = "stuck";
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(json(first)));
    renderApp();
    expect(screen.getByText("Connecting to the engine…")).toBeInTheDocument();
    await screen.findByRole("tab", { name: "Board" });
    expect(screen.getByRole("status")).toHaveTextContent("Reconnecting…");
    const stream = streams.at(-1)!;

    // New warnings count on the Logs tab until it is opened.
    const next = structuredClone(first);
    const warn: LogLine = { at: "2026-10-13T09:00:10Z", source: "api", level: "warn", text: "slow", plan: null };
    next.me.log.push(warn);
    next.me.plans[1].pr = samplePr({ state: "merged", number: 44 });
    next.me.plans[0].cars[1].message = "Writing tests";
    act(() => {
      stream.onState("live");
      stream.onBoard(next);
    });
    const logs = screen.getByRole("tab", { name: /Logs/ });
    expect(logs).toHaveTextContent("Logs1");
    await waitFor(() => expect(screen.getByTestId("announcer")).toHaveTextContent("PR #44 was merged on GitHub. 005 is complete."));
    expect(screen.queryByRole("tab", { name: /001 tests/ })).toBeNull();
    await userEvent.click(logs);
    expect(logs).toHaveTextContent(/^Logs$/);

    // A stuck car with no question: its pill opens the drawer.
    next.me.plans[0].questions = [];
    act(() => stream.onBoard(structuredClone(next)));
    await userEvent.click(pills().getByRole("button", { name: /^001,/ }));
    expect(screen.getByRole("button", { name: "luke-backend" })).toHaveAttribute("aria-expanded", "true");
  });

  it("says when the board cannot be loaded", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response("{}", { status: 500 })));
    renderApp();
    expect(await screen.findByRole("alert")).toHaveTextContent("Could not load the board: GET /api/board answered 500.");
  });
});
