import { Activity, Code2, Coins, Cpu, CreditCard, MessageSquare, Server, Settings, Trophy, type LucideIcon } from "lucide-react";
import type { Workspace, ProviderAccount } from "../console-entry/workspaces";

export interface NavigationItem { href: string; icon: LucideIcon; label: string }

const CONSUMER_GROUPS: Array<{ label: string; items: NavigationItem[] }> = [
  { label: "Workspace", items: [
    { href: "/chat", icon: MessageSquare, label: "Chat" },
    { href: "/models", icon: Cpu, label: "Models" },
    { href: "/api-console", icon: Code2, label: "API console" },
  ] },
  { label: "Network", items: [
    { href: "/stats", icon: Activity, label: "Network stats" },
  ] },
];
const ACCOUNT_ITEMS: NavigationItem[] = [
  { href: "/billing", icon: CreditCard, label: "Billing" },
  { href: "/settings", icon: Settings, label: "Settings" },
];
export function navigationGroups(mode: Workspace, account: ProviderAccount) {
  if (mode === "consumer") return CONSUMER_GROUPS;
  const existing = account.status !== "new" && account.status !== "guest";
  return [
    { label: "Provider workspace", items: [
      { href: "/providers", icon: Server, label: "Your fleet" },
      { href: "/providers/setup", icon: Cpu, label: account.status === "linked" ? "Add a Mac" : "Set up a Mac" },
      ...(existing ? [{ href: "/providers/earnings", icon: Coins, label: "Your earnings" }] : []),
      { href: "/earn", icon: Coins, label: "Earnings calculator" },
    ] },
    { label: "Network", items: [
      { href: "/stats", icon: Activity, label: "Network stats" },
      { href: "/leaderboard", icon: Trophy, label: "Leaderboard" },
    ] },
  ];
}
export function accountItems(mode: Workspace) {
  return mode === "provider" ? ACCOUNT_ITEMS.filter((item) => item.href !== "/billing") : ACCOUNT_ITEMS;
}
export function isNavigationActive(pathname: string, href: string) {
  return href === "/" || href === "/providers" ? pathname === href : pathname === href || pathname.startsWith(`${href}/`);
}
