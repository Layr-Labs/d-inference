"use client";

import "./stats.css";
import type { ReactNode } from "react";

interface StatsObservatoryShellProps {
  children: ReactNode;
}

export function StatsObservatoryShell({ children }: StatsObservatoryShellProps) {
  return (
    <div
      className="relative isolate flex min-h-full flex-1 flex-col overflow-y-auto bg-bg-primary text-text-primary
        before:pointer-events-none before:absolute before:inset-0 before:z-0 before:opacity-55
        before:bg-[radial-gradient(color-mix(in_srgb,var(--text-tertiary)_22%,transparent)_0.65px,transparent_0.65px)]
        before:bg-size-[18px_18px]
        before:[mask-image:linear-gradient(180deg,black_0%,black_72%,transparent_100%)]
        after:pointer-events-none after:absolute after:inset-0 after:z-0
        after:bg-[radial-gradient(ellipse_55%_40%_at_0%_0%,var(--accent-brand-dim),transparent_58%),radial-gradient(ellipse_45%_35%_at_100%_8%,var(--accent-green-dim),transparent_52%)]"
    >
      <div className="relative z-[1] mx-auto w-full max-w-6xl space-y-7 px-3 py-6 sm:px-6 sm:py-10 [&_header_h1]:hidden">
        {children}
      </div>
    </div>
  );
}
