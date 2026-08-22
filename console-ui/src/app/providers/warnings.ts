// Warning derivation for the /providers/me dashboard.
//
// Each warning maps a provider state signal to a user-facing message.
// Severity:
//   - blocking: machine receives ZERO requests
//   - degrading: machine still routable but fewer requests / lower priority
//   - info: worth surfacing, but no material effect on routing or earnings
//
// Keep this in sync with the routing gates and the additive cost function in
// coordinator/registry/scheduler.go, and with the base-reward eligibility gates
// in coordinator/payments/baserewards/engine.go. Routing ranks candidates by
// estimated completion cost in milliseconds; there are no multiplicative
// "weights". Quoted millisecond figures below are the scheduler's penalty
// constants (scheduler.go:17-37), and near-ties within 3s of the cheapest
// candidate are spread by queue depth and randomness rather than by cost.

import type { MyProvider, MyProvidersResponse } from "./types";

export type WarningSeverity = "blocking" | "degrading" | "info";

export interface Warning {
  id: string;
  severity: WarningSeverity;
  title: string;
  detail: string;
}

export function semverLess(a: string, b: string): boolean {
  if (!a) return Boolean(b);
  if (!b) return false;
  const ap = a.split(".").map((n) => parseInt(n, 10) || 0);
  const bp = b.split(".").map((n) => parseInt(n, 10) || 0);
  const len = Math.max(ap.length, bp.length);
  for (let i = 0; i < len; i++) {
    const av = ap[i] ?? 0;
    const bv = bp[i] ?? 0;
    if (av < bv) return true;
    if (av > bv) return false;
  }
  return false;
}

export function computeWarnings(
  p: MyProvider,
  ctx: Pick<
    MyProvidersResponse,
    | "latest_provider_version"
    | "min_provider_version"
    | "heartbeat_timeout_seconds"
    | "challenge_max_age_seconds"
  >
): Warning[] {
  const out: Warning[] = [];

  // Blocking: machine receives no requests.
  if (p.status === "untrusted" || p.failed_challenges >= 3) {
    out.push({
      id: "untrusted",
      severity: "blocking",
      title: "Blocked: failed attestation challenges",
      detail: `${p.failed_challenges} consecutive challenge failures; the coordinator marked this machine untrusted and is not routing to it. Restart the provider and re-link the device.`,
    });
  } else if (p.status === "offline" || p.status === "never_seen") {
    out.push({
      id: "offline",
      severity: "blocking",
      title: p.status === "never_seen" ? "Never connected" : "Offline",
      detail:
        p.status === "never_seen"
          ? "This machine has a stored record but hasn't connected since the coordinator restarted. Start the provider with `darkbloom start`."
          : `No heartbeat in over ${ctx.heartbeat_timeout_seconds || 90} seconds. Start the provider with \`darkbloom start\` to come back online.`,
    });
  }

  if (!p.runtime_verified) {
    out.push({
      id: "runtime_unverified",
      severity: "blocking",
      title: "Runtime hash mismatch",
      detail:
        "Provider runtime hashes do not match the known-good manifest. Reinstall with the latest installer to restore eligibility.",
    });
  }

  if (
    ctx.min_provider_version &&
    p.version &&
    semverLess(p.version, ctx.min_provider_version)
  ) {
    const isOffline = p.status === "offline" || p.status === "never_seen";
    out.push({
      id: "version_below_min",
      severity: "blocking",
      title: "Provider version below the minimum",
      detail: isOffline
        ? `Last seen on v${p.version}; the coordinator requires v${ctx.min_provider_version} or newer. Start the provider — if already updated, the version will refresh automatically.`
        : `Running v${p.version}; the coordinator requires v${ctx.min_provider_version} or newer. Update with the install script before this machine can earn.`,
    });
  }

  if (p.system_metrics?.thermal_state === "critical") {
    out.push({
      id: "thermal_critical",
      severity: "blocking",
      title: "Thermal state critical",
      detail:
        "macOS reports critical thermal pressure. The coordinator excludes this machine from routing entirely and it stops accruing base rewards until the state clears. Cool the machine and ensure adequate ventilation.",
    });
  }

  // Stale attestation challenge: the coordinator excludes providers whose
  // last challenge is older than `challenge_max_age_seconds` (typically 6 min).
  if (
    p.last_challenge_verified &&
    p.status !== "offline" &&
    p.status !== "untrusted" &&
    p.status !== "never_seen"
  ) {
    const ageSec = (Date.now() - new Date(p.last_challenge_verified).getTime()) / 1000;
    if (Number.isFinite(ageSec) && ageSec > (ctx.challenge_max_age_seconds || 360)) {
      out.push({
        id: "challenge_stale",
        severity: "blocking",
        title: "Attestation challenge stale",
        detail: `Last challenge verified ${Math.round(ageSec / 60)} minutes ago. The coordinator drops providers from routing until a fresh handshake completes.`,
      });
    }
  }

  // Trust below the routing threshold. In production the coordinator's
  // MinTrustLevel is "hardware", so anything below that gets ZERO requests
  // (not just a reduced multiplier). We surface it as blocking and tell the
  // user how to upgrade.
  if (
    p.trust_level !== "hardware" &&
    p.status !== "offline" &&
    p.status !== "untrusted" &&
    p.status !== "never_seen"
  ) {
    if (p.trust_level === "self_signed") {
      out.push({
        id: "trust_self_signed",
        severity: "blocking",
        title: "Self-signed trust below routing threshold",
        detail:
          "The network requires hardware-attested machines. Complete MDM enrollment + Apple Device Attestation to start receiving requests.",
      });
    } else {
      out.push({
        id: "trust_none",
        severity: "blocking",
        title: "No attestation below routing threshold",
        detail:
          "This machine hasn't supplied a Secure Enclave attestation. Re-run the installer to register an SE-bound identity, then re-link the device.",
      });
    }
  }

  // Degrading: routable, but fewer / lower-quality requests.

  // A crashed slot is ineligible for that model (slotStatePenalty returns
  // +Inf), but the machine keeps serving its other loaded models, so this is
  // degrading rather than blocking.
  const crashedSlots =
    p.backend_capacity?.slots?.filter((s) => s.state === "crashed") ?? [];
  if (crashedSlots.length > 0) {
    out.push({
      id: "backend_crashed",
      severity: "degrading",
      title: "Backend crashed (model excluded from routing)",
      detail: `Backend(s) for ${crashedSlots
        .map((s) => s.model)
        .join(", ")} report a crashed state. The coordinator routes no requests for those models until you restart the provider; other loaded models keep serving.`,
    });
  }

  if (
    p.trust_level === "hardware" &&
    !p.mda_verified &&
    p.status !== "offline" &&
    p.status !== "never_seen"
  ) {
    out.push({
      id: "mda_missing",
      severity: "info",
      title: "Apple Device Attestation pending",
      detail:
        "This machine is hardware-trusted and earning at full priority — Apple Device Attestation does not affect routing. It's an extra Apple-signed identity proof that consumers can verify; it's earned automatically and reused across restarts. If it stays pending for a long time, keep the Mac awake and reachable so the coordinator can complete it.",
    });
  }

  if (p.system_metrics?.thermal_state === "serious") {
    out.push({
      id: "thermal_serious",
      severity: "degrading",
      title: "Thermal state serious (+8s routing cost)",
      detail:
        "macOS reports the system is throttling, so the scheduler adds 8 seconds to this machine's estimated cost and prefers cooler peers. Base rewards are unaffected. Improve cooling to recover routing priority.",
    });
  } else if (p.system_metrics?.thermal_state === "fair") {
    out.push({
      id: "thermal_fair",
      severity: "info",
      title: "Thermal state fair (+2s routing cost)",
      detail:
        "Thermal state comes from macOS, not a temperature threshold Darkbloom sets — a desktop under sustained load often reads fair while running cool. The 2 seconds of routing cost stay inside the 3-second near-tie window, so an otherwise-equal machine still competes for the same traffic, and base rewards are unaffected.",
    });
  }

  if ((p.system_metrics?.memory_pressure ?? 0) > 0.9) {
    out.push({
      id: "memory_pressure_high",
      severity: "degrading",
      title: "Memory pressure very high",
      detail: `${(p.system_metrics!.memory_pressure * 100).toFixed(0)}% memory pressure adds up to 4 seconds of routing cost, and 80% or higher stops base rewards from accruing. Close other apps or upgrade RAM.`,
    });
  }

  const idleSlots =
    p.backend_capacity?.slots?.filter((s) => s.state === "idle_shutdown") ?? [];
  if (idleSlots.length > 0) {
    out.push({
      id: "backend_idle_shutdown",
      severity: "degrading",
      title: "Backend cold (+20s routing cost)",
      detail: `Backend(s) for ${idleSlots
        .map((s) => s.model)
        .join(", ")} were unloaded after 1h of idle. The scheduler adds 20 seconds to this machine's cost for those models, so warm peers win until the next request reloads them.`,
    });
  }

  if (p.reputation.total_jobs > 0) {
    const successRate =
      p.reputation.successful_jobs / p.reputation.total_jobs;
    if (successRate < 0.8 && p.reputation.total_jobs >= 10) {
      out.push({
        id: "low_success_rate",
        severity: "degrading",
        title: `Job success rate low (${(successRate * 100).toFixed(0)}%)`,
        detail: `Reputation score: ${p.reputation.score.toFixed(2)}. Investigate failed jobs in the logs to recover routing priority.`,
      });
    }
  }

  // No catalog models: provider is online and trusted but didn't pass any
  // models through the coordinator's catalog filter (either none of its
  // models are in the catalog, or weight hashes mismatched). Routing
  // requires `model in p.Models`, so this is effectively blocking even
  // though scoring doesn't zero it out.
  if (
    p.models.length === 0 &&
    p.status !== "offline" &&
    p.status !== "untrusted" &&
    p.status !== "never_seen"
  ) {
    out.push({
      id: "no_catalog_models",
      severity: "blocking",
      title: "No catalog models served",
      detail:
        "None of this machine's local models matched the coordinator catalog (or weight hashes did not match). Download an approved model and restart the provider.",
    });
  }

  // Info: configuration to fix.
  if (
    !p.account_id &&
    !p.wallet_address &&
    p.status !== "offline" &&
    p.status !== "never_seen"
  ) {
    out.push({
      id: "no_payout",
      severity: "info",
      title: "No payout method configured",
      detail:
        "This machine has no account link and no wallet address. Earnings cannot be claimed. Run `darkbloom login` to link to your account.",
    });
  }

  if (
    ctx.latest_provider_version &&
    p.version &&
    semverLess(p.version, ctx.latest_provider_version) &&
    !out.some((w) => w.id === "version_below_min")
  ) {
    const isOffline = p.status === "offline" || p.status === "never_seen";
    out.push({
      id: "outdated_version",
      severity: "info",
      title: isOffline
        ? "Version may be outdated"
        : "Newer provider version available",
      detail: isOffline
        ? `Last seen on v${p.version}. Latest is v${ctx.latest_provider_version}. Start the provider to verify — if already updated, the version will refresh automatically.`
        : `Running v${p.version}. Latest is v${ctx.latest_provider_version}. Update via the installer when convenient.`,
    });
  }

  // Visibility check: if the machine should appear in the public marketplace
  // (online + hardware trust) but isn't routable due to a stale challenge.
  if (
    p.status !== "offline" &&
    p.status !== "untrusted" &&
    p.status !== "never_seen" &&
    p.trust_level === "hardware" &&
    !p.last_challenge_verified
  ) {
    out.push({
      id: "no_challenge_yet",
      severity: "info",
      title: "Awaiting first attestation challenge",
      detail:
        "The machine is online but the coordinator has not yet completed a challenge handshake. Routing will start within ~5 minutes.",
    });
  }

  return out;
}

export function highestSeverity(warnings: Warning[]): WarningSeverity | null {
  if (warnings.some((w) => w.severity === "blocking")) return "blocking";
  if (warnings.some((w) => w.severity === "degrading")) return "degrading";
  if (warnings.some((w) => w.severity === "info")) return "info";
  return null;
}
