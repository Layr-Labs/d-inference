import { describe, expect, it } from "vitest";
import { providerDestination, workspaceForPath } from "./workspaces";
import { accountItems, isNavigationActive, navigationGroups } from "../navigation/items";

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
