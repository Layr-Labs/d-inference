import { describe, it, expect, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import {
  VerificationModeProvider,
  useVerificationMode,
} from "@/lib/verification-mode";

// ---------------------------------------------------------------------------
// Test component that exposes the hook values
// ---------------------------------------------------------------------------

function ModeDisplay() {
  const { mode, toggle } = useVerificationMode();
  return (
    <div>
      <span data-testid="mode">{mode}</span>
      <button onClick={toggle}>Toggle</button>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("VerificationModeProvider", () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it("defaults to normal mode", () => {
    render(
      <VerificationModeProvider>
        <ModeDisplay />
      </VerificationModeProvider>
    );
    expect(screen.getByTestId("mode").textContent).toBe("normal");
  });

  it("toggles to technical mode", () => {
    render(
      <VerificationModeProvider>
        <ModeDisplay />
      </VerificationModeProvider>
    );
    fireEvent.click(screen.getByText("Toggle"));
    expect(screen.getByTestId("mode").textContent).toBe("technical");
  });

  it("toggles back to normal mode", () => {
    render(
      <VerificationModeProvider>
        <ModeDisplay />
      </VerificationModeProvider>
    );
    fireEvent.click(screen.getByText("Toggle"));
    expect(screen.getByTestId("mode").textContent).toBe("technical");
    fireEvent.click(screen.getByText("Toggle"));
    expect(screen.getByTestId("mode").textContent).toBe("normal");
  });

  it("persists mode to localStorage", () => {
    render(
      <VerificationModeProvider>
        <ModeDisplay />
      </VerificationModeProvider>
    );
    fireEvent.click(screen.getByText("Toggle"));
    expect(localStorage.getItem("darkbloom-verification-mode")).toBe(
      "technical"
    );
  });

  it("reads persisted mode from localStorage", () => {
    localStorage.setItem("darkbloom-verification-mode", "technical");
    render(
      <VerificationModeProvider>
        <ModeDisplay />
      </VerificationModeProvider>
    );
    expect(screen.getByTestId("mode").textContent).toBe("technical");
  });

  it("ignores invalid localStorage values", () => {
    localStorage.setItem("darkbloom-verification-mode", "garbage");
    render(
      <VerificationModeProvider>
        <ModeDisplay />
      </VerificationModeProvider>
    );
    expect(screen.getByTestId("mode").textContent).toBe("normal");
  });
});


