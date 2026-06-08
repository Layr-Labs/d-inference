"use client";

// Thin orchestrator: fetch the fleet, branch on auth/loading/error/empty, and
// otherwise compose the header, fleet verdict strip, attention feed, machine
// grid, and trust footer. All derivation lives in aggregate.ts / routing.ts;
// this file just wires data to sections.

import { useMemo } from "react";
import { useFleetData } from "./useFleetData";
import { semverLess } from "../warnings";
import {
  buildAttentionGroups,
  deriveFleetVerdict,
  fleetMaxDecodeTps,
  onlineCount,
} from "./aggregate";
import { DashboardHeader } from "./DashboardHeader";
import { FleetHealthStrip } from "./FleetHealthStrip";
import { AttentionFeed } from "./AttentionFeed";
import { MachineGrid } from "./MachineGrid";
import { TrustFooter } from "./TrustFooter";
import { OnboardingState } from "./OnboardingState";
import { SignInGate, LoadingState, ErrorState } from "./states";

export function ProviderDashboard() {
  const {
    ready,
    authenticated,
    login,
    providersResp,
    summary,
    ctx,
    loading,
    refreshing,
    error,
    pollFailed,
    lastUpdatedAt,
    refetch,
  } = useFleetData();

  const providers = useMemo(() => providersResp?.providers ?? [], [providersResp]);

  const verdict = useMemo(() => deriveFleetVerdict(providers, ctx), [providers, ctx]);
  const groups = useMemo(() => buildAttentionGroups(providers, ctx), [providers, ctx]);
  const maxDecode = useMemo(() => fleetMaxDecodeTps(providers), [providers]);
  const hardwareCount = useMemo(
    () => providers.filter((p) => p.trust_level === "hardware").length,
    [providers]
  );
  // "Update available" nudges machines running below the latest release (the
  // below-minimum case is already surfaced as a blocking attention row).
  const updateAvailable = useMemo(
    () =>
      providers.some(
        (p) => p.version && ctx.latest_provider_version && semverLess(p.version, ctx.latest_provider_version)
      ),
    [providers, ctx.latest_provider_version]
  );

  if (!ready) return <Shell><LoadingState /></Shell>;
  if (!authenticated) return <Shell><SignInGate onLogin={login} /></Shell>;
  if (loading && !providersResp) return <Shell><LoadingState /></Shell>;
  if (error && !providersResp) return <Shell><ErrorState message={error} onRetry={refetch} /></Shell>;

  // No machines yet — the onboarding flow owns the whole page.
  if (providers.length === 0) {
    return (
      <Shell>
        <OnboardingState />
      </Shell>
    );
  }

  return (
    <Shell>
      <DashboardHeader
        total={providers.length}
        online={onlineCount(providers)}
        latestVersion={providersResp?.latest_provider_version ?? ""}
        refreshing={refreshing}
        onRefresh={refetch}
        lastUpdatedAt={lastUpdatedAt}
        pollFailed={pollFailed}
        updateAvailable={updateAvailable}
      />
      <FleetHealthStrip verdict={verdict} summary={summary} />
      <AttentionFeed groups={groups} />
      <MachineGrid providers={providers} ctx={ctx} fleetMaxDecodeTps={maxDecode} />
      <TrustFooter hardwareCount={hardwareCount} total={providers.length} />
    </Shell>
  );
}

function Shell({ children }: { children: React.ReactNode }) {
  return <div className="max-w-6xl mx-auto px-6 py-6 space-y-6">{children}</div>;
}
