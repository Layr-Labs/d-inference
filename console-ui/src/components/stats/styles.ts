/** Shared Tailwind class bundles for the stats dashboard. */

export const statsReveal = "stats-reveal";
export const statsReveal1 = "stats-reveal stats-reveal-1";
export const statsReveal2 = "stats-reveal stats-reveal-2";
export const statsReveal3 = "stats-reveal stats-reveal-3";
export const statsReveal4 = "stats-reveal stats-reveal-4";
export const statsReveal5 = "stats-reveal stats-reveal-5";
export const statsReveal6 = "stats-reveal stats-reveal-6";

export const statsPanel =
  "relative rounded-[0.35rem] border border-border-dim bg-bg-primary shadow-sm overflow-hidden";

export const statsMetricLabel =
  "font-mono text-[0.58rem] tracking-[0.2em] uppercase text-text-tertiary mb-1.5";

export const statsMetricValue =
  "font-mono font-bold tracking-[-0.045em] leading-[0.88] text-text-primary";

export const statsMetricSub = "mt-2 font-mono text-[0.68rem] text-text-tertiary";

export const statsSectionIndex =
  "shrink-0 font-mono text-[0.68rem] font-bold tracking-wider text-accent-brand pt-0.5 opacity-85";

export const statsMapLegend =
  "pointer-events-none absolute left-4 top-4 z-30 flex flex-wrap items-center gap-2 rounded border border-border-dim bg-bg-primary/90 px-3 py-2 shadow-sm backdrop-blur";

export const statsChartCard =
  "relative rounded-[0.35rem] border border-border-dim bg-bg-primary p-5 shadow-sm overflow-hidden";

export const statsChartCanvas =
  "relative h-44 overflow-hidden rounded border border-border-dim bg-linear-to-b from-accent-brand-dim to-transparent bg-bg-secondary";

export const statsTokenBar =
  "rounded-[0.35rem] border border-border-dim bg-bg-primary px-5 py-5 shadow-sm";

export const statsCapacityGrid =
  "grid grid-cols-[minmax(0,2.2fr)_repeat(4,minmax(3.25rem,1fr))] items-center gap-2 px-3.5 py-2";

export const statsFlowTickerCell =
  "px-3.5 py-3 transition-colors hover:bg-accent-brand-dim/45";

export const statsModelCard =
  "relative overflow-hidden rounded-[0.35rem] border border-border-dim bg-bg-secondary px-4 py-4 shadow-sm transition-[border-color,transform,box-shadow] hover:border-accent-brand/30 hover:-translate-y-0.5 hover:shadow-md";

export const statsModelCardLeader =
  "border-accent-brand/35 bg-linear-to-br from-accent-brand-dim via-transparent to-bg-secondary";

export const statsFilterPill =
  "rounded border border-border-dim bg-bg-secondary px-3 py-1.5 font-mono text-[0.68rem] tracking-wide uppercase text-text-secondary transition-colors hover:border-border-subtle hover:bg-bg-hover hover:text-text-primary";

export const statsFilterPillActive =
  "border-accent-brand/35 bg-accent-brand-dim text-accent-brand";

export const statsFilterPillTrustActive =
  "border-accent-green/35 bg-accent-green-dim text-accent-green";

export const statsMapStageFlow =
  "rounded border border-border-dim bg-bg-secondary shadow-[inset_0_1px_0_color-mix(in_srgb,var(--bg-white)_50%,transparent),inset_0_-24px_48px_color-mix(in_srgb,var(--text-primary)_4%,transparent)] bg-[linear-gradient(180deg,color-mix(in_srgb,var(--bg-primary)_70%,transparent),transparent_40%),radial-gradient(ellipse_at_50%_38%,var(--accent-brand-dim),transparent_50%),radial-gradient(ellipse_at_82%_62%,var(--accent-green-dim),transparent_32%),var(--bg-secondary)]";

export const statsMapStageDemand =
  "rounded-[0.35rem] border border-border-dim bg-bg-secondary shadow-[inset_0_1px_0_color-mix(in_srgb,var(--accent-green)_8%,transparent)] bg-[radial-gradient(ellipse_at_50%_42%,var(--accent-green-dim),transparent_55%),var(--bg-secondary)]";

export const statsMapTheaterCorners =
  "before:pointer-events-none before:absolute before:top-2.5 before:left-2.5 before:z-40 before:size-5.5 before:border-t-2 before:border-l-2 before:border-accent-brand/35 after:pointer-events-none after:absolute after:right-2.5 after:bottom-2.5 after:z-40 after:size-5.5 after:border-r-2 after:border-b-2 after:border-accent-brand/35";

export const statsMapLegendDemand =
  "border-accent-green/25 bg-[color-mix(in_srgb,var(--bg-primary)_88%,var(--accent-green-dim))]";

export const statsPanelDemand =
  "bg-[linear-gradient(180deg,color-mix(in_srgb,var(--accent-green-dim)_35%,var(--bg-primary)),var(--bg-primary))]";
