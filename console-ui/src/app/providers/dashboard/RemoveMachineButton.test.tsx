// @vitest-environment jsdom
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent, waitFor } from "@testing-library/react";
import { RemoveMachineButton } from "./RemoveMachineButton";
import { makeProvider } from "./testFixtures";

const getAccessToken = vi.fn(async () => "tok");
vi.mock("@/hooks/useAuth", () => ({
  useAuth: () => ({ getAccessToken }),
}));

const addToast = vi.fn();
vi.mock("@/hooks/useToast", () => ({
  useToastStore: (selector: (s: { addToast: typeof addToast }) => unknown) =>
    selector({ addToast }),
}));

const deleteProvider = vi.fn(async () => {});
vi.mock("@/lib/api", () => ({
  deleteProvider: (...args: unknown[]) => deleteProvider(...args),
}));

const REMOVE_BTN = { name: "Remove machine" } as const;

beforeEach(() => {
  vi.clearAllMocks();
  getAccessToken.mockResolvedValue("tok");
  deleteProvider.mockResolvedValue(undefined);
  vi.spyOn(window, "confirm").mockReturnValue(true);
});

describe("RemoveMachineButton", () => {
  it("confirms, deletes by serial_number, toasts success, and calls onRemoved", async () => {
    const onRemoved = vi.fn();
    render(
      <RemoveMachineButton provider={makeProvider({ serial_number: "SER-1", id: "p1" })} onRemoved={onRemoved} />
    );
    fireEvent.click(screen.getByRole("button", REMOVE_BTN));

    await waitFor(() => expect(deleteProvider).toHaveBeenCalledWith("tok", "SER-1"));
    await waitFor(() => expect(onRemoved).toHaveBeenCalled());
    expect(addToast).toHaveBeenCalledWith("Machine removed.", "success");
  });

  it("falls back to the provider id when serial_number is empty", async () => {
    render(<RemoveMachineButton provider={makeProvider({ serial_number: "", id: "p9" })} />);
    fireEvent.click(screen.getByRole("button", REMOVE_BTN));
    await waitFor(() => expect(deleteProvider).toHaveBeenCalledWith("tok", "p9"));
  });

  it("does nothing when the confirm dialog is cancelled", async () => {
    vi.spyOn(window, "confirm").mockReturnValue(false);
    const onRemoved = vi.fn();
    render(<RemoveMachineButton provider={makeProvider()} onRemoved={onRemoved} />);
    fireEvent.click(screen.getByRole("button", REMOVE_BTN));

    // Give any (incorrectly-scheduled) async work a chance to run.
    await Promise.resolve();
    expect(deleteProvider).not.toHaveBeenCalled();
    expect(onRemoved).not.toHaveBeenCalled();
    expect(addToast).not.toHaveBeenCalled();
  });

  it("surfaces the coordinator error message and does not call onRemoved", async () => {
    deleteProvider.mockRejectedValue(new Error("machine is currently online — stop it before removing"));
    const onRemoved = vi.fn();
    render(<RemoveMachineButton provider={makeProvider()} onRemoved={onRemoved} />);
    fireEvent.click(screen.getByRole("button", REMOVE_BTN));

    await waitFor(() =>
      expect(addToast).toHaveBeenCalledWith(
        "machine is currently online — stop it before removing",
        "error"
      )
    );
    expect(onRemoved).not.toHaveBeenCalled();
  });

  it("warns and aborts when no auth token is available", async () => {
    getAccessToken.mockResolvedValue(null as unknown as string);
    render(<RemoveMachineButton provider={makeProvider()} />);
    fireEvent.click(screen.getByRole("button", REMOVE_BTN));

    await waitFor(() =>
      expect(addToast).toHaveBeenCalledWith("Sign in again to remove this machine.", "error")
    );
    expect(deleteProvider).not.toHaveBeenCalled();
  });

  it("disables the button and shows a removing state while in flight", async () => {
    let resolveDelete: () => void = () => {};
    deleteProvider.mockImplementation(
      () => new Promise<void>((resolve) => { resolveDelete = resolve; })
    );
    render(<RemoveMachineButton provider={makeProvider()} />);
    const btn = screen.getByRole("button", REMOVE_BTN);
    fireEvent.click(btn);

    await waitFor(() => expect(btn).toBeDisabled());
    expect(screen.getByText("Removing…")).toBeInTheDocument();

    resolveDelete();
    await waitFor(() => expect(btn).not.toBeDisabled());
  });
});
