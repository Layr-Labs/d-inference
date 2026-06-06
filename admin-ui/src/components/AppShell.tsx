import Link from "next/link";
import type { ReactNode } from "react";

const NAV: { href: string; label: string }[] = [
  { href: "/", label: "Overview" },
  { href: "/users", label: "Users" },
  { href: "/providers", label: "Machines" },
  { href: "/operators", label: "Operators" },
  { href: "/uptime", label: "Uptime" },
  { href: "/usage", label: "Usage" },
  { href: "/billing", label: "Billing" },
  { href: "/earnings", label: "Earnings" },
  { href: "/api-keys", label: "API Keys" },
  { href: "/models", label: "Models" },
  { href: "/openrouter", label: "OpenRouter" },
  { href: "/releases", label: "Releases" },
  { href: "/referrals", label: "Referrals" },
];

export function AppShell({ children }: { children: ReactNode }) {
  return (
    <div className="flex min-h-screen">
      <aside className="w-52 shrink-0 border-r border-[var(--border)] bg-[var(--bg-elevated)] p-4">
        <div className="mb-6">
          <div className="text-sm font-semibold">Darkbloom</div>
          <div className="text-xs text-[var(--text-faint)]">admin · read-only</div>
        </div>
        <nav className="flex flex-col gap-1">
          {NAV.map((n) => (
            <Link
              key={n.href}
              href={n.href}
              className="rounded px-2 py-1.5 text-[var(--text-dim)] hover:bg-[var(--bg-hover)] hover:text-[var(--text)]"
            >
              {n.label}
            </Link>
          ))}
        </nav>
      </aside>
      <main className="min-w-0 flex-1 p-6">{children}</main>
    </div>
  );
}
