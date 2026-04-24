// Warning derivation for the /providers/me dashboard.
//
// Each warning maps a provider state signal to a user-facing message.
// Severity:
//   - blocking: machine receives ZERO requests
//   - degrading: machine still routable but fewer requests / lower priority
//   - info: configuration issue worth surfacing (e.g. payout setup)
//
// Keep this in sync with coordinator/internal/registry/registry.go scoring
// rules and FindProviderWithTrust exclusion checks.

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
    out.push({
      id: "version_below_min",
      severity: "blocking",
      title: "Provider version below the minimum",
      detail: `Running v${p.version}; the coordinator requires v${ctx.min_provider_version} or newer. Update with the install script before this machine can earn.`,
    });
  }

  if (p.system_metrics?.thermal_state === "critical") {
    out.push({
      id: "thermal_critical",
      severity: "blocking",
      title: "Thermal state critical",
      detail:
        "Health factor is zero; the coordinator will not route work. Cool the machine and ensure adequate ventilation.",
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

  // Backend slot states reported as crashed score 0.05x; the provider can
  // still be selected if it's the only candidate, but it loses routing
  // priority sharply. Treat as degrading, not blocking.
  const crashedSlots =
    p.backend_capacity?.slots?.filter((s) => s.state === "crashed") ?? [];
  if (crashedSlots.length > 0) {
    out.push({
      id: "backend_crashed",
      severity: "degrading",
      title: "Backend crashed (0.05x routing weight)",
      detail: `Backend(s) for ${crashedSlots
        .map((s) => s.model)
        .join(", ")} report a crashed state. The coordinator will prefer healthier machines until you restart the provider.`,
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
      severity: "degrading",
      title: "Apple Device Attestation incomplete",
      detail:
        "MDA proves to consumers that this is a real Apple device. Without it, some consumers will skip this machine.",
    });
  }

  if (p.system_metrics?.thermal_state === "serious") {
    out.push({
      id: "thermal_serious",
      severity: "degrading",
      title: "Thermal state serious (0.4x health)",
      detail: "The system is throttling. Improve cooling to recover routing weight.",
    });
  } else if (p.system_metrics?.thermal_state === "fair") {
    out.push({
      id: "thermal_fair",
      severity: "degrading",
      title: "Thermal state fair (0.8x health)",
      detail: "Mild thermal pressure detected.",
    });
  }

  if ((p.system_metrics?.memory_pressure ?? 0) > 0.9) {
    out.push({
      id: "memory_pressure_high",
      severity: "degrading",
      title: "Memory pressure very high",
      detail: `${(p.system_metrics!.memory_pressure * 100).toFixed(0)}% memory pressure caps health to 0.1x. Close other apps or upgrade RAM.`,
    });
  }

  const idleSlots =
    p.backend_capacity?.slots?.filter((s) => s.state === "idle_shutdown") ?? [];
  if (idleSlots.length > 0) {
    out.push({
      id: "backend_idle_shutdown",
      severity: "degrading",
      title: "Backend cold (0.1x weight on cold start)",
      detail: `Backend(s) for ${idleSlots
        .map((s) => s.model)
        .join(", ")} were unloaded after 1h of idle. Next request will pay a ~10-30s cold-start penalty.`,
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
    out.push({
      id: "outdated_version",
      severity: "info",
      title: "Newer provider version available",
      detail: `Running v${p.version}. Latest is v${ctx.latest_provider_version}. Update via the installer when convenient.`,
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
