import { beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { ConsoleWelcome } from "./ConsoleWelcome";
import { providerDestination, workspaceForPath, summarizeProviders, type ProviderAccount } from "./workspaces";
import { accountItems, isNavigationActive, navigationGroups } from "../navigation/items";

const state = vi.hoisted(() => ({ account: { status: "guest", total: 0, online: 0 } as ProviderAccount, login: vi.fn(), choose: vi.fn(), retry: vi.fn() }));
vi.mock("./ConsoleExperience", () => ({ useConsoleExperience: () => ({ providerAccount: state.account, chooseWorkspace: state.choose, retryProviders: state.retry, lastWorkspace: null }) }));
vi.mock("@/components/providers/PrivyClientProvider", () => ({ useAuthContext: () => ({ ready: true, authenticated: state.account.status !== "guest", login: state.login }) }));
vi.mock("@/components/providers/ThemeProvider", () => ({ useTheme: () => ({ theme: "light", toggleTheme: vi.fn() }) }));

beforeEach(() => { state.account = { status: "guest", total: 0, online: 0 }; vi.clearAllMocks(); });

describe("Console entrance", () => {
  it("offers public setup and direct consumer destinations without requiring a role or sign-in", () => {
    render(<ConsoleWelcome />);
    expect(screen.getByRole("link", { name: "Consumer: Open chat" })).toHaveAttribute("href", "/chat");
    expect(screen.getByRole("link", { name: "Provider: Set up your first Mac" })).toHaveAttribute("href", "/providers/setup");
    expect(screen.getByRole("link", { name: "Building an app? Use the API" })).toHaveAttribute("href", "/api-console");
    fireEvent.click(screen.getByRole("button", { name: "Already providing? Sign in" }));
    expect(state.login).toHaveBeenCalledOnce();
  });
  it("returns offline providers to recovery and actual earnings rather than reinstalling", () => {
    state.account = summarizeProviders({ providers: [{ id: "mac", online: false, status: "never_seen" }] });
    render(<ConsoleWelcome />);
    expect(screen.getByRole("link", { name: "Provider: Open your fleet" })).toHaveAttribute("href", "/providers");
    expect(screen.getByText(/1 Mac linked · 0 online/)).toBeVisible();
    expect(screen.getByRole("link", { name: "View your earnings" })).toHaveAttribute("href", "/providers/earnings");
    expect(screen.queryByText("Set up your first Mac")).not.toBeInTheDocument();
  });
  it.each(["loading", "error"] as const)("never describes %s discovery as an empty fleet", (status) => {
    state.account = { status, total: 0, online: 0 };
    render(<ConsoleWelcome />);
    expect(screen.getByRole("link", { name: "Provider: Open provider workspace" })).toHaveAttribute("href", "/providers");
    expect(screen.queryByText("Set up your first Mac")).not.toBeInTheDocument();
    if (status === "error") { fireEvent.click(screen.getByRole("button", { name: "Retry" })); expect(state.retry).toHaveBeenCalledOnce(); }
  });
});

describe("Workspace routing", () => {
  it("treats roles as navigation preferences while retaining shared pages and deep links", () => {
    expect(workspaceForPath("/chat")).toBe("consumer");
    expect(workspaceForPath("/providers/earnings")).toBe("provider");
    expect(workspaceForPath("/link")).toBeNull();
    expect(workspaceForPath("/settings")).toBeNull();
    expect(workspaceForPath("/stats")).toBeNull();
    expect(providerDestination({ status: "new", total: 0, online: 0 })).toBe("/providers/setup");
    expect(isNavigationActive("/providers/setup", "/providers")).toBe(false);
  });
  it("separates provider earnings from consumer billing and the calculator", () => {
    const items = navigationGroups("provider", { status: "linked", total: 1, online: 1 }).flatMap((group) => group.items);
    expect(items.find((item) => item.label === "Your earnings")?.href).toBe("/providers/earnings");
    expect(items.find((item) => item.label === "Earnings calculator")?.href).toBe("/earn");
    expect(items.some((item) => item.href === "/chat")).toBe(false);
    expect(accountItems("provider").some((item) => item.href === "/billing")).toBe(false);
    expect(accountItems("consumer").some((item) => item.href === "/billing")).toBe(true);
  });
});
