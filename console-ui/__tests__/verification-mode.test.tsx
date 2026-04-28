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

// ---------------------------------------------------------------------------
// Serial masking (tested via TrustBadge integration, but also unit-testable)
// ---------------------------------------------------------------------------

describe("maskSerial", () => {
  // The maskSerial function is defined locally in VerificationPanel and
  // E2ELockIndicator. We test the logic here to ensure correctness.
  function maskSerial(serial: string): string {
    if (serial.length <= 6) return serial;
    return (
      serial.slice(0, 4) +
      "\u2022".repeat(serial.length - 6) +
      serial.slice(-2)
    );
  }

  it("masks a 10-char serial", () => {
    expect(maskSerial("L7Q172774D")).toBe("L7Q1\u2022\u2022\u2022\u20224D");
  });

  it("preserves serials 6 chars or shorter", () => {
    expect(maskSerial("ABC")).toBe("ABC");
    expect(maskSerial("ABCDEF")).toBe("ABCDEF");
  });

  it("masks a 7-char serial correctly", () => {
    expect(maskSerial("ABCDEFG")).toBe("ABCD\u2022FG");
  });

  it("handles empty string", () => {
    expect(maskSerial("")).toBe("");
  });
});
