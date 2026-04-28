"use client";

import { TopBar } from "@/components/TopBar";
import { Link, usePathname } from "@/i18n/navigation";
import { useTranslations } from "next-intl";

export default function ProvidersLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const pathname = usePathname();
  const t = useTranslations("ProvidersLayout");
  const tabs = [
    { href: "/providers", label: t("dashboard") },
    { href: "/providers/setup", label: t("setup") },
    { href: "/providers/earnings", label: t("earnings") },
  ];

  return (
    <div className="flex flex-col h-full">
      <TopBar title={t("title")} />
      <div className="border-b border-border-dim bg-bg-primary">
        <div className="max-w-5xl mx-auto px-6">
          <nav className="flex gap-1">
            {tabs.map(({ href, label }) => {
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
