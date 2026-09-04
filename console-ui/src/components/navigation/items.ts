import { Activity, Code2, Coins, Cpu, CreditCard, MessageSquare, Server, Settings, Trophy, type LucideIcon } from "lucide-react";

export interface NavigationItem { href: string; icon: LucideIcon; label: string }

export const NAVIGATION_GROUPS: Array<{ label: string; items: NavigationItem[] }> = [
  { label: "Workspace", items: [
    { href: "/", icon: MessageSquare, label: "Chat" },
    { href: "/models", icon: Cpu, label: "Models" },
    { href: "/api-console", icon: Code2, label: "API console" },
  ] },
  { label: "Network", items: [
    { href: "/stats", icon: Activity, label: "Network stats" },
    { href: "/providers", icon: Server, label: "Provider fleet" },
    { href: "/earn", icon: Coins, label: "Earnings" },
    { href: "/leaderboard", icon: Trophy, label: "Leaderboard" },
  ] },
];
export const ACCOUNT_ITEMS: NavigationItem[] = [
  { href: "/billing", icon: CreditCard, label: "Billing" },
  { href: "/settings", icon: Settings, label: "Settings" },
];
export function isNavigationActive(pathname: string, href: string) {
  return href === "/" ? pathname === "/" : pathname === href || pathname.startsWith(`${href}/`);
}
