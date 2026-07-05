// @vitest-environment jsdom
import { describe, it, expect, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { VerificationModeProvider, useVerificationMode } from "./verification-mode";
import { STORAGE_KEYS } from "@/lib/constants";

// Records the mode on every render so a test can assert the FIRST render is
// deterministic (server-safe) even when localStorage diverges. Reading
// localStorage in the useState initializer was what diverged the first client
// render from the server HTML and caused the hydration mismatch that broke
// client-side navigation app-wide.
let renders: string[] = [];

function Probe() {
  const { mode, toggle } = useVerificationMode();
  renders.push(mode);
  return (
    <button data-testid="mode" onClick={toggle}>
      {mode}
    </button>
  );
}

beforeEach(() => {
  localStorage.clear();
  renders = [];
});

describe("VerificationModeProvider hydration determinism", () => {
  it("first render is 'normal' even when localStorage says technical, then applies it after mount", () => {
    localStorage.setItem(STORAGE_KEYS.verificationMode, "technical");

    render(
      <VerificationModeProvider>
        <Probe />
      </VerificationModeProvider>,
    );

    // The first client render must match the server (which has no localStorage):
    // "normal". A divergent first render is the hydration mismatch we're fixing.
    expect(renders[0]).toBe("normal");
    // After the mount effect, the persisted preference is applied.
    expect(screen.getByTestId("mode").textContent).toBe("technical");
  });

  it("stays 'normal' on first render and after mount when nothing is persisted", () => {
    render(
      <VerificationModeProvider>
        <Probe />
      </VerificationModeProvider>,
    );

    expect(renders[0]).toBe("normal");
    expect(screen.getByTestId("mode").textContent).toBe("normal");
  });

  it("toggle flips the mode and persists it, and toggles back", () => {
    render(
      <VerificationModeProvider>
        <Probe />
      </VerificationModeProvider>,
    );

    expect(screen.getByTestId("mode").textContent).toBe("normal");
    fireEvent.click(screen.getByTestId("mode"));
    expect(screen.getByTestId("mode").textContent).toBe("technical");
    expect(localStorage.getItem(STORAGE_KEYS.verificationMode)).toBe("technical");
    fireEvent.click(screen.getByTestId("mode"));
    expect(screen.getByTestId("mode").textContent).toBe("normal");
  });

  it("ignores invalid persisted values and stays in normal mode", () => {
    localStorage.setItem(STORAGE_KEYS.verificationMode, "garbage");

    render(
      <VerificationModeProvider>
        <Probe />
      </VerificationModeProvider>,
    );

    expect(screen.getByTestId("mode").textContent).toBe("normal");
  });
});
