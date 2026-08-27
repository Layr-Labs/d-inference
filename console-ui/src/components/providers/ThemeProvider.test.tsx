// @vitest-environment jsdom
import { fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ThemeProvider, useTheme } from "./ThemeProvider";

describe("ThemeProvider", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("renders and changes theme when browser storage is denied", () => {
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new DOMException("blocked", "SecurityError");
    });
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new DOMException("blocked", "SecurityError");
    });
    function ThemeControl() {
      const { theme, toggleTheme } = useTheme();
      return <button onClick={toggleTheme}>{theme}</button>;
    }

    expect(() =>
      render(
        <ThemeProvider>
          <ThemeControl />
        </ThemeProvider>
      )
    ).not.toThrow();
    const button = screen.getByRole("button", { name: "light" });
    expect(() => fireEvent.click(button)).not.toThrow();
    expect(screen.getByRole("button", { name: "dark" })).toBeInTheDocument();
  });
});
