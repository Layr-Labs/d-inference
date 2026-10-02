import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ThemeProvider, useTheme } from "./ThemeProvider";
import { initializeTheme, THEME_STORAGE_KEY } from "@/lib/theme";

let dark = false;
let mediaListeners: Set<() => void>;

function Controls() {
  const { theme, preference, setTheme } = useTheme();
  return <>
    <output>{`${preference}:${theme}`}</output>
    <button onClick={() => setTheme("light")}>Light</button>
    <button onClick={() => setTheme("dark")}>Dark</button>
    <button onClick={() => setTheme("system")}>System</button>
  </>;
}

beforeEach(() => {
  localStorage.clear();
  document.documentElement.classList.remove("dark");
  dark = false;
  mediaListeners = new Set();
  vi.stubGlobal("matchMedia", vi.fn(() => ({
    get matches() { return dark; },
    addEventListener: (_: string, listener: () => void) => mediaListeners.add(listener),
    removeEventListener: (_: string, listener: () => void) => mediaListeners.delete(listener),
  })));
});
afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

describe("console appearance", () => {
  it("applies a saved choice before React mounts, including the legacy key", () => {
    localStorage.setItem("eigeninference-theme", "dark");
    expect(initializeTheme()).toEqual({ preference: "dark", theme: "dark" });
    expect(document.documentElement).toHaveClass("dark");
    localStorage.setItem(THEME_STORAGE_KEY, "light");
    expect(initializeTheme().theme).toBe("light");
    expect(document.documentElement).not.toHaveClass("dark");
    expect(document.documentElement.style.colorScheme).toBe("light");
  });

  it("persists explicit choices and follows OS changes only in System mode", () => {
    render(<ThemeProvider><Controls /></ThemeProvider>);
    expect(screen.getByRole("status")).toHaveTextContent("system:light");
    fireEvent.click(screen.getByRole("button", { name: "Dark" }));
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe("dark");
    act(() => { mediaListeners.forEach((listener) => listener()); });
    expect(screen.getByRole("status")).toHaveTextContent("dark:dark");
    fireEvent.click(screen.getByRole("button", { name: "System" }));
    act(() => { dark = true; mediaListeners.forEach((listener) => listener()); });
    expect(screen.getByRole("status")).toHaveTextContent("system:dark");
    expect(document.documentElement).toHaveClass("dark");
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe("system");
  });

  it("updates when another tab changes or clears the saved preference", () => {
    render(<ThemeProvider><Controls /></ThemeProvider>);
    act(() => {
      localStorage.setItem(THEME_STORAGE_KEY, "dark");
      window.dispatchEvent(new StorageEvent("storage", { key: THEME_STORAGE_KEY }));
    });
    expect(screen.getByRole("status")).toHaveTextContent("dark:dark");
    act(() => {
      localStorage.clear();
      window.dispatchEvent(new StorageEvent("storage", { key: null }));
    });
    expect(screen.getByRole("status")).toHaveTextContent("system:light");
  });

  it("keeps appearance usable when browser storage is blocked", () => {
    vi.spyOn(localStorage, "getItem").mockImplementation(() => { throw new Error("blocked"); });
    vi.spyOn(localStorage, "setItem").mockImplementation(() => { throw new Error("blocked"); });
    render(<ThemeProvider><Controls /></ThemeProvider>);
    fireEvent.click(screen.getByRole("button", { name: "Dark" }));
    expect(document.documentElement).toHaveClass("dark");
    expect(screen.getByRole("status")).toHaveTextContent("dark:dark");
  });
});
