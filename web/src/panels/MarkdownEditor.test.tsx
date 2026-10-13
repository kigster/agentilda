import { act, fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { axe } from "vitest-axe";
import { MarkdownEditor } from "./MarkdownEditor";
import { renderMarkdown } from "./markdown";
import { typeInEditor } from "./testing";

function Harness({ onSubmit, initial = "" }: { onSubmit?: () => void; initial?: string }) {
  const [value, setValue] = useState(initial);
  return <MarkdownEditor value={value} onChange={setValue} onSubmit={onSubmit} label="Your answer" placeholder="Type here" height="180px" resizable />;
}

describe("MarkdownEditor", () => {
  it("is a real CodeMirror editor, labelled, with Edit pressed", async () => {
    const { container } = render(<Harness />);
    expect(screen.getByRole("textbox", { name: "Your answer" })).toHaveClass("cm-content");
    expect(screen.getByRole("button", { name: "Edit" })).toHaveAttribute("aria-pressed", "true");
    expect(screen.getByRole("button", { name: "Preview" })).toHaveAttribute("aria-pressed", "false");
    expect(container.querySelector(".md")).toHaveClass("is-resizable");
    expect(await axe(container)).toHaveNoViolations();
  });

  it("submits on Ctrl Enter", () => {
    const onSubmit = vi.fn();
    const { container } = render(<Harness onSubmit={onSubmit} />);
    let content!: HTMLElement;
    act(() => { content = typeInEditor(container, "hello"); });
    fireEvent.keyDown(content, { key: "Enter", code: "Enter", keyCode: 13, ctrlKey: true });
    expect(onSubmit).toHaveBeenCalledTimes(1);
  });

  it("swaps to a preview of the rendered Markdown and back", async () => {
    const user = userEvent.setup();
    const { container } = render(<Harness />);
    act(() => { typeInEditor(container, "# Title\n\n```ruby\nputs 1\n```\n"); });
    await user.click(screen.getByRole("button", { name: "Preview" }));
    const preview = screen.getByLabelText("Preview of your answer");
    expect(preview.querySelector("h1")).toHaveTextContent("Title");
    expect(preview.querySelector("code.hljs .hljs-built_in, code.hljs span")).not.toBeNull();
    expect(screen.queryByRole("textbox")).toBeNull();
    await user.click(screen.getByRole("button", { name: "Edit" }));
    expect(screen.getByRole("textbox", { name: "Your answer" })).toHaveTextContent("# Title");
  });

  it("says when there is nothing to preview", async () => {
    render(<Harness />);
    await userEvent.click(screen.getByRole("button", { name: "Preview" }));
    expect(screen.getByText("Nothing to preview yet.")).toBeInTheDocument();
  });

  it("marks itself invalid and can hide the switch", () => {
    const { container } = render(<MarkdownEditor value="" onChange={() => {}} label="Idea" preview={false} invalid />);
    expect(screen.queryByRole("button", { name: "Preview" })).toBeNull();
    expect(container.querySelector(".md")).toHaveClass("is-invalid");
    expect(screen.getByRole("textbox", { name: "Idea" })).toHaveAttribute("aria-invalid", "true");
  });

  it("follows data-theme", async () => {
    const { container } = render(<Harness />);
    const editor = container.querySelector(".cm-editor")!;
    const light = editor.className;
    await act(async () => { document.documentElement.dataset.theme = "dark"; await new Promise((r) => setTimeout(r, 0)); });
    expect(container.querySelector(".cm-editor")!.className).not.toBe(light);
    await act(async () => { delete document.documentElement.dataset.theme; await new Promise((r) => setTimeout(r, 0)); });
  });
});

describe("renderMarkdown", () => {
  it("strips scripts, opens links in a new tab and leaves unknown languages alone", () => {
    const html = renderMarkdown('<script>alert(1)</script>\n\n[x](https://example.com)\n\n```nosuchlang\nplain\n```\n\n```\nbare\n```');
    expect(html).not.toContain("<script");
    expect(html).toContain('target="_blank"');
    expect(html).toContain('rel="noopener noreferrer"');
    expect(html).toContain("plain");
    expect(html).not.toContain("hljs");
  });
});
