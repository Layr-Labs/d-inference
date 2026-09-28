import { describe, expect, it } from "vitest";
import { providerDestination, summarizeProviders, workspaceForPath, type ProviderAccount } from "./workspaces";
import { accountItems, isNavigationActive, navigationGroups } from "../navigation/items";

const EARNINGS_PATH = "/providers/earnings";

describe("Workspace routing", () => {
  it("keeps earnings reachable after the last Mac is removed and the account is reloaded", () => {
    const linked = summarizeProviders({ providers: [{ id: "mac-1", online: true }] });
    const removed = summarizeProviders({ providers: [] });
    expect(removed.status).toBe("new");
    for (const account of [linked, removed]) {
      const items = navigationGroups("provider", account).flatMap((group) => group.items);
      expect(items.find((item) => item.label === "Your earnings")?.href).toBe(EARNINGS_PATH);
    }
  });
  it.each<ProviderAccount["status"]>(["guest", "loading", "error", "new", "linked"])(
    "keeps the earnings entry available when provider discovery is %s",
    (status) => {
      const items = navigationGroups("provider", { status, total: 0, online: 0 }).flatMap((group) => group.items);
      expect(items.some((item) => item.href === EARNINGS_PATH)).toBe(true);
    },
  );
  it("treats roles as navigation preferences while retaining shared pages and deep links", () => {
    expect(workspaceForPath("/chat")).toBe("consumer");
    expect(workspaceForPath(EARNINGS_PATH)).toBe("provider");
    expect(workspaceForPath("/link")).toBeNull();
    expect(workspaceForPath("/settings")).toBeNull();
    expect(workspaceForPath("/stats")).toBeNull();
    expect(providerDestination({ status: "new", total: 0, online: 0 })).toBe("/providers/setup");
    expect(isNavigationActive("/providers/setup", "/providers")).toBe(false);
  });
  it("separates provider earnings from consumer billing and the calculator", () => {
    const items = navigationGroups("provider", { status: "linked", total: 1, online: 1 }).flatMap((group) => group.items);
    expect(items.find((item) => item.label === "Your earnings")?.href).toBe(EARNINGS_PATH);
    expect(items.find((item) => item.label === "Earnings calculator")?.href).toBe("/earn");
    expect(items.some((item) => item.href === "/chat")).toBe(false);
    expect(accountItems("provider").some((item) => item.href === "/billing")).toBe(false);
    expect(accountItems("consumer").some((item) => item.href === "/billing")).toBe(true);
  });
});
