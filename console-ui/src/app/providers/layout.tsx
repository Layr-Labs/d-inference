"use client";

// Native <a> navigation (not next/link): the App Router client-router path is
// currently broken for shell/tab navigation (see #457/#458) — Link renders but
// router.push silently no-ops, so the tabs don't switch pages. Browser-native
// route loads always work. Mirrors the sidebar workaround in #458.
import { TopBar } from "@/components/TopBar";
import { usePathname } from "next/navigation";
import { useHasLinkedProviders } from "./useHasLinkedProviders";

const DASHBOARD_TAB = { href: "/providers", label: "Dashboard" };
// Setup and Earnings are post-install surfaces — shown only once the account has
// at least one linked machine. Before that, the Dashboard's onboarding state
// owns the "set up a provider" flow.
const POST_INSTALL_TABS = [
  { href: "/providers/setup", label: "Setup" },
  { href: "/providers/earnings", label: "Earnings" },
];

export default function ProvidersLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const pathname = usePathname();
  const hasProviders = useHasLinkedProviders();
  const tabs = hasProviders ? [DASHBOARD_TAB, ...POST_INSTALL_TABS] : [DASHBOARD_TAB];

  return (
    <div className="flex flex-col h-full">
      <TopBar title="Provider Dashboard" />
      <div className="border-b border-border-dim bg-bg-primary">
        <div className="max-w-5xl mx-auto px-6">
          <nav className="flex gap-1">
            {tabs.map(({ href, label }) => {
              const isActive = pathname === href;
              return (
                <a
                  key={href}
                  href={href}
                  className={`px-4 py-3 text-sm font-medium border-b-2 transition-colors ${
                    isActive
                      ? "border-accent-brand text-accent-brand"
                      : "border-transparent text-text-tertiary hover:text-text-secondary"
                  }`}
                >
                  {label}
                </a>
              );
            })}
          </nav>
        </div>
      </div>
      <div className="flex-1 overflow-y-auto">{children}</div>
    </div>
  );
}
