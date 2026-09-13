"use client";

import { useMemo, useState } from "react";
import type { PlatformStats } from "../platform-types";
import { HardwareIdentity } from "./HardwareIdentity";
import { buildHardwareComposition, formatHardwareMemory, hardwareShare, type HardwareFamily } from "./hardware-composition";

function familySummary(family?: HardwareFamily): string {
  if (!family) return "Select a generation to compare its share of machines and memory.";
  const subject = family.providers === 1 ? "provider contributes" : "providers contribute";
  return `${family.providers.toLocaleString()} ${family.label} ${subject} ${formatHardwareMemory(family.memoryGB)} of reported memory.`;
}

const CIRCUMFERENCE = 2 * Math.PI * 68;
const FAMILY_TONES = new Map([
  ["m1", 25], ["m2", 39], ["m3", 57], ["m4", 77], ["m5", 100],
]);

function familyColor(family: HardwareFamily): string {
  if (family.key === "unknown") return "var(--border-subtle)";
  if (family.key === "other") return "var(--text-tertiary)";
  const tone = FAMILY_TONES.get(family.key) ?? 57;
  return `color-mix(in srgb, var(--accent-brand) ${tone}%, var(--bg-white))`;
}

export function HardwareComposition({ stats }: { stats: PlatformStats }) {
  const data = useMemo(() => buildHardwareComposition(stats), [stats]);
  const [activeKey, setActiveKey] = useState<string | null>(null);
  const families = data.chartFamilies;
  const active = families.find((family) => family.key === activeKey);
  const memoryFamilies = [...families].sort((a, b) => b.memoryGB - a.memoryGB || a.label.localeCompare(b.label));
  const colors = new Map(families.map((family) => [family.key, familyColor(family)]));
  const arcs = families.map((family, index) => {
    const share = family.providers / Math.max(data.providers, 1);
    const start = families.slice(0, index).reduce((sum, previous) => sum + previous.providers, 0) / Math.max(data.providers, 1);
    return { family, start, share };
  });
  const nodeMismatch = data.coordinatorProviders !== null && data.coordinatorProviders !== data.providers;
  const memoryMismatch = data.coordinatorMemoryGB !== null && data.coordinatorMemoryGB !== data.memoryGB;

  return (
    <section aria-labelledby="hardware-composition-title" className="border-t border-border-dim pt-8">
      <div className="mb-7 flex flex-wrap items-end justify-between gap-3">
        <div>
          <h2 id="hardware-composition-title" className="text-lg font-medium tracking-[-0.02em] text-text-primary">The silicon behind the network</h2>
          <p className="mt-1 text-sm text-text-secondary">How connected Macs contribute machines and memory.</p>
        </div>
        <p className="text-xs text-text-tertiary">{data.providers.toLocaleString()} listed providers</p>
      </div>
      {data.providers === 0 ? (
        <div className="border-y border-border-dim py-10 text-center text-sm text-text-secondary">Hardware composition will appear when provider details are available.</div>
      ) : (
        <div className="grid gap-8 lg:grid-cols-2 lg:gap-12">
          <div>
            <div className="mb-5 flex items-baseline justify-between gap-3">
              <h3 className="text-sm font-medium text-text-primary">Silicon mix</h3>
              <p className="text-xs text-text-tertiary">Share of providers</p>
            </div>
            <div className="grid items-center gap-5 min-[430px]:grid-cols-[minmax(150px,0.9fr)_minmax(0,1fr)]">
              <div className="relative mx-auto aspect-square w-full max-w-[215px]">
                <svg viewBox="0 0 180 180" className="h-full w-full -rotate-90" aria-hidden="true">
                  <circle cx="90" cy="90" r="68" fill="none" stroke="var(--bg-secondary)" strokeWidth="23" />
                  {arcs.map(({ family, start, share }) => (
                    <circle key={family.key} cx="90" cy="90" r="68" fill="none" stroke={colors.get(family.key)} strokeWidth={activeKey === family.key ? 27 : 23}
                      strokeDasharray={`${share * CIRCUMFERENCE} ${CIRCUMFERENCE}`} strokeDashoffset={-start * CIRCUMFERENCE}
                      opacity={active && active.key !== family.key ? .28 : 1}
                      className="transition-[stroke-width,opacity] duration-200 motion-reduce:transition-none" />
                  ))}
                </svg>
                <div className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center text-center">
                  <p className="text-[37px] font-medium leading-none tracking-[-0.055em] tabular-nums text-text-primary">{(active?.providers ?? data.providers).toLocaleString()}</p>
                  <p className="mt-2 max-w-24 text-xs leading-snug text-text-secondary">{active ? `${active.label} providers` : "listed providers"}</p>
                </div>
              </div>
              <ul className="grid grid-cols-2 gap-x-3 gap-y-0.5 min-[430px]:grid-cols-1">
                {families.map((family) => (
                  <li key={family.key}>
                    <button type="button" onMouseEnter={() => setActiveKey(family.key)} onMouseLeave={(event) => { if (event.currentTarget !== document.activeElement) setActiveKey(null); }} onFocus={() => setActiveKey(family.key)} onBlur={() => setActiveKey(null)} onClick={() => setActiveKey(family.key)}
                      aria-label={`${family.label}: ${family.providers.toLocaleString()} ${family.providers === 1 ? "provider" : "providers"}, ${hardwareShare(family.providers, data.providers)} of listed providers; ${family.memoryGB.toLocaleString()} GB of reported memory`}
                      className="flex min-h-10 w-full items-center gap-2.5 rounded-md px-1.5 text-left text-[13px] transition-colors hover:bg-bg-secondary focus-visible:outline-2 focus-visible:outline-accent-brand">
                      <span aria-hidden="true" className="h-2.5 w-2.5 shrink-0 rounded-[3px]" style={{ backgroundColor: colors.get(family.key) }} />
                      <span className="min-w-0 flex-1 truncate text-text-secondary">{family.label}</span>
                      <span className="font-medium tabular-nums text-text-primary">{hardwareShare(family.providers, data.providers)}</span>
                    </button>
                  </li>
                ))}
              </ul>
            </div>
            <p role="status" aria-live="polite" aria-atomic="true" className="mt-4 min-h-5 text-xs leading-relaxed text-text-secondary">
              {familySummary(active)}
            </p>
          </div>

          <div className="lg:border-l lg:border-border-dim lg:pl-10">
            <div className="mb-5 flex flex-wrap items-baseline justify-between gap-2">
              <h3 className="text-sm font-medium text-text-primary">Memory by generation</h3>
              <p className="text-xs text-text-tertiary">{formatHardwareMemory(data.memoryGB)} reported</p>
            </div>
            {data.memoryGB === 0 ? (
              <div className="flex min-h-48 items-center justify-center text-sm text-text-secondary">Memory sizes haven’t been reported yet.</div>
            ) : (
              <ol className="space-y-4" aria-label="Share of reported memory by silicon generation">
                {memoryFamilies.map((family) => (
                  <li key={family.key} className="transition-opacity duration-150 motion-reduce:transition-none" style={{ opacity: active && active.key !== family.key ? .45 : 1 }}>
                    <div className="mb-1.5 flex items-baseline justify-between gap-3 text-[13px]">
                      <span className="text-text-secondary">{family.label}</span>
                      <span className="tabular-nums text-text-primary">{formatHardwareMemory(family.memoryGB)} <span className="ml-1.5 text-xs text-text-tertiary">{hardwareShare(family.memoryGB, data.memoryGB)}</span></span>
                    </div>
                    <div className="h-3 overflow-hidden rounded-[3px] bg-bg-secondary" role="img" aria-label={`${family.label}: ${family.memoryGB.toLocaleString()} GB, ${hardwareShare(family.memoryGB, data.memoryGB)} of reported memory`}>
                      <div className="h-full rounded-[3px] transition-[width] duration-300 motion-reduce:transition-none" style={{ width: `${family.memoryGB / data.memoryGB * 100}%`, backgroundColor: colors.get(family.key) }} />
                    </div>
                  </li>
                ))}
              </ol>
            )}
            <p className="mt-4 text-xs leading-relaxed text-text-tertiary">Physical memory across machines, not free inference capacity.{data.memoryUnreportedProviders > 0 ? ` ${data.memoryUnreportedProviders.toLocaleString()} providers have no reported memory size.` : ""}</p>
          </div>
        </div>
      )}

      {data.providers > 0 && <HardwareIdentity data={data} />}
      {(nodeMismatch || memoryMismatch) && (
        <p className="mt-5 text-xs leading-relaxed text-text-tertiary">Charts use the listed providers. The coordinator summary reports {data.coordinatorProviders?.toLocaleString() ?? "an unknown number of"} connected providers and {data.coordinatorMemoryGB === null ? "an unknown amount of memory" : formatHardwareMemory(data.coordinatorMemoryGB)}.</p>
      )}
    </section>
  );
}
