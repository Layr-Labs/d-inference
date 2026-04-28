"use client";

import { TopBar } from "@/components/TopBar";
import Link from "next/link";
import { usePathname } from "next/navigation";

const TABS = [
  { href: "/providers", label: "Dashboard" },
  { href: "/providers/setup", label: "Setup" },
  { href: "/providers/pricing", label: "Pricing" },
  { href: "/providers/earnings", label: "Earnings" },
];

export default function ProvidersLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const pathname = usePathname();

  return (
    <div className="flex flex-col h-full">
      <TopBar title="Provider Dashboard" />
      <div className="border-b border-border-dim bg-bg-primary">
        <div className="max-w-5xl mx-auto px-6">
          <nav className="flex gap-1">
            {TABS.map(({ href, label }) => {
              const isActive = pathname === href;
              return (
                <Link
                  key={href}
                  href={href}
                  className={`px-4 py-3 text-sm font-medium border-b-2 transition-colors ${
                    isActive
                      ? "border-accent-brand text-accent-brand"
                      : "border-transparent text-text-tertiary hover:text-text-secondary"
                  }`}
                >
                  {label}
                </Link>
              );
            })}
          </nav>
        </div>
      </div>
      <div className="flex-1 overflow-y-auto">{children}</div>
    </div>
  );
}
