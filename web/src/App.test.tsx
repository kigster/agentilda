import { render, screen } from "@testing-library/react";
import App from "./App";
import type { Board } from "./api/types";
import board from "./api/fixtures/board.json";

it("renders", () => {
  render(<App />);
  expect(screen.getByRole("main")).toBeInTheDocument();
});

it("has a fixture that satisfies the Board contract", () => {
  const typed: Board = board as Board;
  expect(typed.me.plans.length).toBeGreaterThan(0);
});
