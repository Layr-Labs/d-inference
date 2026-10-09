import type { ReactNode } from "react";

export function SettingsSection({ title, description, children }: { title: string; description: string; children: ReactNode }) {
  return (
    <section className="grid gap-5 py-8 sm:grid-cols-[minmax(0,1fr)_minmax(0,2fr)] sm:gap-10">
      <div>
        <h2 className="text-sm font-medium text-text-primary">{title}</h2>
        <p className="mt-2 max-w-xs text-sm leading-relaxed text-text-secondary">{description}</p>
      </div>
      <div className="min-w-0">{children}</div>
    </section>
  );
}
