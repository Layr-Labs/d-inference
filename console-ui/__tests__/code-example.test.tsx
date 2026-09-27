import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { CodeExample } from "@/components/CodeExample";

const examples = [
  { label: "Python", language: "python", code: "print('hello')" },
  { label: "JavaScript", language: "javascript", code: "console.log('hello')" },
];

function mockClipboard(writeText: (text: string) => Promise<void>) {
  vi.spyOn(navigator, "clipboard", "get").mockReturnValue({ writeText } as Clipboard);
}

Object.defineProperty(navigator, "clipboard", { configurable: true, get: () => undefined });
afterEach(() => vi.restoreAllMocks());

describe("code examples", () => {
  it("reports copied only after the clipboard write succeeds", async () => {
    let finishCopy: () => void = () => {};
    const writeText = vi.fn().mockReturnValue(new Promise<void>((resolve) => { finishCopy = resolve; }));
    mockClipboard(writeText);
    render(<CodeExample examples={examples} />);
    fireEvent.click(screen.getByRole("button", { name: "Copy" }));
    expect(screen.getByRole("button", { name: "Copying…" })).toBeDisabled();
    expect(screen.queryByText("Copied")).not.toBeInTheDocument();
    await act(async () => { finishCopy(); });
    expect(screen.getByRole("button", { name: "Copied" })).toBeEnabled();
    expect(writeText).toHaveBeenCalledWith(examples[0].code);
  });

  it("shows recovery instructions when the clipboard rejects the request", async () => {
    mockClipboard(vi.fn().mockRejectedValue(new Error("Permission denied")));
    render(<CodeExample examples={examples} />);
    await act(async () => { fireEvent.click(screen.getByRole("button", { name: "Copy" })); });
    expect(screen.getByRole("status")).toHaveTextContent("Copy failed. Select the code below and copy it manually");
    expect(screen.getByRole("button", { name: "Copy" })).toBeEnabled();
    expect(screen.queryByText("Copied")).not.toBeInTheDocument();
  });

  it("keeps copy feedback attached to the selected example when a pending copy finishes", async () => {
    let finishCopy: () => void = () => {};
    mockClipboard(vi.fn().mockReturnValue(new Promise<void>((resolve) => { finishCopy = resolve; })));
    render(<CodeExample examples={examples} />);
    fireEvent.click(screen.getByRole("button", { name: "Copy" }));
    fireEvent.click(screen.getByRole("tab", { name: "JavaScript" }));
    await act(async () => { finishCopy(); });
    expect(screen.getByRole("tabpanel")).toHaveTextContent(examples[1].code);
    expect(screen.getByRole("button", { name: "Copy" })).toBeEnabled();
    expect(screen.queryByText("Copied")).not.toBeInTheDocument();
  });

  it("supports keyboard tab selection and copies the active language", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    mockClipboard(writeText);
    render(<CodeExample examples={examples} />);
    fireEvent.keyDown(screen.getByRole("tab", { name: "Python" }), { key: "ArrowRight" });
    expect(screen.getByRole("tab", { name: "JavaScript" })).toHaveFocus();
    expect(screen.getByRole("tab", { name: "JavaScript" })).toHaveAttribute("aria-selected", "true");
    await act(async () => { fireEvent.click(screen.getByRole("button", { name: "Copy" })); });
    expect(writeText).toHaveBeenCalledWith(examples[1].code);
  });
});
