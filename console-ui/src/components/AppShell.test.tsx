// @vitest-environment jsdom
import { render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { AppShell } from "./AppShell";

vi.mock("next/navigation", () => ({
  usePathname: () => "/provider-waitlist",
}));

describe("AppShell public flows", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("renders the waitlist without touching denied browser storage", () => {
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new DOMException("blocked", "SecurityError");
    });

    expect(() =>
      render(
        <AppShell>
          <p>Public waitlist</p>
        </AppShell>
      )
    ).not.toThrow();
    expect(screen.getByText("Public waitlist")).toBeInTheDocument();
  });
});
