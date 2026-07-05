// Maps each warning id from warnings.ts to a concrete "what can I do about it"
// fix. This is the actionability backbone of the dashboard: every problem the
// operator sees comes with a copyable command, a link, or clear guidance.
//
// INVARIANT: every warning id produced by computeWarnings() must have an entry
// here. __tests__/provider-dashboard-fixes.test.ts enforces this so the
// guarantee can't silently regress when a new warning is added.

export type FixKind = "command" | "link" | "guidance";

export interface FixAction {
  kind: FixKind;
  /** Short affordance label (button / link text). */
  label: string;
  /** Shell command to copy (kind === "command"). */
  command?: string;
  /** In-app or external href (kind === "link"). */
  href?: string;
  /** Optional one-line elaboration shown under the affordance. */
  note?: string;
}

/** The canonical install one-liner, matching scripts/install.sh + setup page. */
export const INSTALL_COMMAND = "curl -fsSL https://api.darkbloom.dev/install.sh | bash";

const FIX_TABLE: Record<string, FixAction> = {
  // ── Blocking ───────────────────────────────────────────────────────────
  untrusted: {
    kind: "command",
    label: "Restart & re-link",
    command: "darkbloom restart && darkbloom login",
    note: "Clears failed challenges, then re-attests this device.",
  },
  offline: {
    kind: "command",
    label: "Start the provider",
    command: "darkbloom start",
  },
  runtime_unverified: {
    kind: "command",
    label: "Reinstall",
    command: INSTALL_COMMAND,
    note: "Restores known-good runtime hashes.",
  },
  version_below_min: {
    kind: "command",
    label: "Update now",
    command: INSTALL_COMMAND,
    note: "Brings this machine up to the required minimum version.",
  },
  thermal_critical: {
    kind: "guidance",
    label: "Cool the machine",
    note: "Routing resumes once the thermal state drops below critical — improve ventilation.",
  },
  challenge_stale: {
    kind: "command",
    label: "Force a fresh handshake",
    command: "darkbloom restart",
    note: "Re-runs the attestation challenge so routing can resume.",
  },
  trust_self_signed: {
    kind: "link",
    label: "Complete hardware attestation",
    href: "/providers/setup",
    note: "The network requires MDM enrollment + Apple Device Attestation.",
  },
  trust_none: {
    kind: "command",
    label: "Register an SE identity",
    command: `${INSTALL_COMMAND} && darkbloom login`,
    note: "Reinstall to create a Secure Enclave identity, then re-link.",
  },
  no_catalog_models: {
    kind: "link",
    label: "Add an approved model",
    href: "/models",
    note: "Download a catalog model, then run `darkbloom restart`.",
  },

  // ── Degrading ──────────────────────────────────────────────────────────
  backend_crashed: {
    kind: "command",
    label: "Restart the provider",
    command: "darkbloom restart",
  },
  mda_missing: {
    kind: "guidance",
    label: "Automatic — no setup needed",
    note: "Earned automatically once the coordinator completes the Apple attestation, then reused across restarts. Keep the Mac awake and reachable if it stays pending.",
  },
  thermal_serious: {
    kind: "guidance",
    label: "Improve cooling",
    note: "The system is throttling and losing routing weight.",
  },
  thermal_fair: {
    kind: "guidance",
    label: "Monitor airflow",
    note: "Mild thermal pressure — improve airflow if it persists.",
  },
  memory_pressure_high: {
    kind: "guidance",
    label: "Free up memory",
    note: "Close other apps (or add RAM) — high pressure caps health to 0.1x.",
  },
  backend_idle_shutdown: {
    kind: "guidance",
    label: "No action needed",
    note: "Model was unloaded after idle; the next request pays a ~10–30s cold start.",
  },
  low_success_rate: {
    kind: "link",
    label: "Inspect failed jobs",
    href: "/providers/earnings",
    note: "Then check the provider logs to recover routing priority.",
  },

  // ── Info ───────────────────────────────────────────────────────────────
  no_payout: {
    kind: "command",
    label: "Link to your account",
    command: "darkbloom login",
  },
  outdated_version: {
    kind: "command",
    label: "Update (optional)",
    command: INSTALL_COMMAND,
  },
  no_challenge_yet: {
    kind: "guidance",
    label: "No action needed",
    note: "Routing starts within ~5 minutes of the first attestation challenge.",
  },
};

/** Safe fallback so an unmapped warning still points somewhere useful. */
export const GENERIC_FIX: FixAction = {
  kind: "link",
  label: "View setup guide",
  href: "/providers/setup",
};

/** Resolve a warning id to its fix, falling back to a generic link. */
export function resolveFix(warningId: string): FixAction {
  return FIX_TABLE[warningId] ?? GENERIC_FIX;
}

/** Whether a warning id has an explicit (non-fallback) fix. */
export function hasFix(warningId: string): boolean {
  return warningId in FIX_TABLE;
}

export { FIX_TABLE };
