// One machine, top to bottom: identity header, the EARNING/NOT-EARNING hero
// verdict, live vitals, models, earnings, and progressive-disclosure detail
// (backend slots + the attestation chain). The left rail color and verdict all
// come from routing.ts so this card can never disagree with the fleet strip or
// the attention feed.

import { Cpu, ShieldCheck, Zap } from "lucide-react";
import type { MyProvider } from "../types";
import { computeWarnings } from "../warnings";
import { deriveRouting, routingMeta, selectTopWarning, type RoutingCtx } from "./routing";
import { maskSerial } from "./format";
import { StatusPill, TrustPill } from "./StatusPill";
import { CardRoutingVerdict } from "./CardRoutingVerdict";
import { CardVitals } from "./CardVitals";
import { ModelsStrip } from "./ModelsStrip";
import { CardEarningsRow } from "./CardEarningsRow";
import { BackendSlotsPanel } from "./BackendSlotsPanel";
import { AttestationPanel } from "./AttestationPanel";
import { ExpandSection } from "./gauges/ExpandSection";
import { RemoveMachineButton } from "./RemoveMachineButton";

export function MachineCard({
  provider,
  ctx,
  fleetMaxDecodeTps,
  onRemoved,
}: {
  provider: MyProvider;
  ctx: RoutingCtx;
  fleetMaxDecodeTps: number;
  onRemoved?: () => void;
}) {
  // Compute this machine's warnings once and derive everything (rail color,
  // hero verdict, the top reason to surface) from the shared routing module so
  // the card agrees with the fleet strip and attention feed.
  const warnings = computeWarnings(provider, ctx);
  const state = deriveRouting(provider, warnings);
  const meta = routingMeta(state);
  const topWarning = selectTopWarning(warnings);
  const dimmed = state === "offline"; // desaturate the body, but keep it actionable
  // Only offer "Remove" for a retired/offline machine — an online box would
  // just re-register (and the coordinator refuses with 409), so hiding the
  // affordance there avoids a dead end.
  const removable = provider.status === "offline" || provider.status === "never_seen";

  // Identity subline — drop any piece the machine didn't report.
  const chipName = provider.hardware.chip_name || "Unknown chip";
  const subline = [
    provider.hardware.machine_model,
    provider.hardware.memory_gb ? `${provider.hardware.memory_gb}GB` : null,
    provider.hardware.gpu_cores ? `${provider.hardware.gpu_cores} GPU` : null,
    provider.serial_number ? maskSerial(provider.serial_number) : null,
    provider.version ? `v${provider.version}` : null,
  ]
    .filter(Boolean)
    .join(" · ");

  return (
    <div
      id={`machine-${provider.id}`}
      className={`scroll-mt-24 rounded-xl bg-bg-secondary shadow-sm border border-border-dim border-l-[3px] ${meta.rail} overflow-hidden transition-shadow hover:shadow-md`}
    >
      {/* Header: identity tile + status/trust pills */}
      <div className={`p-4 flex items-start justify-between gap-3 ${dimmed ? "opacity-70" : ""}`}>
        <div className="flex items-center gap-3 min-w-0">
          <div className="relative w-10 h-10 rounded-lg bg-accent-brand/10 flex items-center justify-center shrink-0">
            <Cpu size={20} className="text-accent-brand" />
            {/* Pulsing dot when actively serving traffic */}
            {provider.status === "serving" && (
              <span className="absolute -top-0.5 -right-0.5 w-2.5 h-2.5 rounded-full bg-accent-green ring-2 ring-bg-secondary animate-pulse" />
            )}
          </div>
          <div className="min-w-0">
            <h3 className="text-sm font-semibold text-text-primary truncate">{chipName}</h3>
            {subline && <p className="text-[11px] font-mono text-text-tertiary truncate">{subline}</p>}
          </div>
        </div>
        <div className="flex flex-col items-end gap-1.5 shrink-0">
          <StatusPill status={provider.status} />
          <TrustPill trustLevel={provider.trust_level} />
          {removable && <RemoveMachineButton provider={provider} onRemoved={onRemoved} />}
        </div>
      </div>

      {/* The hero: EARNING / NOT EARNING verdict with the why + fix inline */}
      <CardRoutingVerdict provider={provider} state={state} topWarning={topWarning} />

      {/* Always-visible body: live vitals, models, then earnings */}
      <div className={dimmed ? "opacity-70" : ""}>
        <CardVitals provider={provider} fleetMaxDecodeTps={fleetMaxDecodeTps} />
        <ModelsStrip provider={provider} />
        <CardEarningsRow provider={provider} />
      </div>

      {/* Progressive disclosure: deep detail stays collapsed by default */}
      {provider.backend_capacity && (
        <ExpandSection label="Backend slots" icon={Zap} right={`${provider.backend_capacity.slots.length} model${provider.backend_capacity.slots.length === 1 ? "" : "s"}`}>
          <BackendSlotsPanel cap={provider.backend_capacity} />
        </ExpandSection>
      )}

      <ExpandSection label="Trust & attestation" icon={ShieldCheck}>
        <AttestationPanel provider={provider} challengeMaxAgeSeconds={ctx.challenge_max_age_seconds} />
      </ExpandSection>
    </div>
  );
}
