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

  // ── Coordinator routing verdict ────────────────────────────────────────
  // One entry per RoutingBlocker the coordinator can report (see
  // coordinator/registry/routing_diagnostics.go). Per-model blockers are keyed
  // without the model id; resolveFix strips it.
  "routing:offline": {
    kind: "command",
    label: "Start the provider",
    command: "darkbloom start",
  },
  "routing:untrusted": {
    kind: "command",
    label: "Restart & re-link",
    command: "darkbloom restart && darkbloom login",
    note: "Clears the untrust, then re-attests this device.",
  },
  "routing:private_only": {
    kind: "guidance",
    label: "Intentional — private mode",
    note: "Disable private-only mode if you want this machine to earn from public network traffic.",
  },
  "routing:trust_below_minimum": {
    kind: "link",
    label: "Complete hardware attestation",
    href: "/providers/setup",
    note: "The network requires MDM enrollment + Apple Device Attestation.",
  },
  "routing:runtime_hash_mismatch": {
    kind: "command",
    label: "Reinstall",
    command: INSTALL_COMMAND,
    note: "Replaces a self-updated or partial bundle with a manifest-matching one.",
  },
  "routing:attestation_challenge_never_passed": {
    kind: "guidance",
    label: "No action needed",
    note: "Routing starts within ~5 minutes of the first attestation challenge.",
  },
  "routing:attestation_challenge_stale": {
    kind: "command",
    label: "Force a fresh handshake",
    command: "darkbloom restart",
    note: "Re-runs the attestation challenge so routing can resume.",
  },
  "routing:no_encryption_key": {
    kind: "command",
    label: "Restart the provider",
    command: "darkbloom restart",
    note: "Republishes this machine's end-to-end encryption key.",
  },
  "routing:unsupported_backend": {
    kind: "command",
    label: "Reinstall",
    command: INSTALL_COMMAND,
  },
  "routing:unencrypted_response_chunks": {
    kind: "command",
    label: "Reinstall",
    command: INSTALL_COMMAND,
  },
  "routing:runtime_manifest_unchecked": {
    kind: "command",
    label: "Reinstall",
    command: INSTALL_COMMAND,
    note: "Installs a build the coordinator can match to a registered release.",
  },
  "routing:sip_unverified": {
    kind: "guidance",
    label: "Re-enable SIP",
    note: "Boot into Recovery, run `csrutil enable`, reboot, then `darkbloom restart`.",
  },
  "routing:code_attestation_missing": {
    kind: "guidance",
    label: "Keep the Mac awake",
    note: "Code-identity attestation completes over an APNs push; it needs the Mac awake and reachable.",
  },
  "routing:privacy_capabilities_missing": {
    kind: "command",
    label: "Reinstall",
    command: INSTALL_COMMAND,
  },
  "routing:privacy_capabilities_incomplete": {
    kind: "command",
    label: "Restart the provider",
    command: "darkbloom restart",
    note: "If it persists after a restart, reinstall with the official installer.",
  },
  "routing:no_models_registered": {
    kind: "command",
    label: "Check local models",
    command: "darkbloom models",
    note: "Confirm the weights finished downloading and that `enabled_models` is not filtering them out, then `darkbloom restart`.",
  },
  "routing:no_routable_models": {
    kind: "link",
    label: "Add an approved model",
    href: "/models",
    note: "Download a catalog model, then run `darkbloom restart`.",
  },
  "routing:model:model_not_in_catalog": {
    kind: "guidance",
    label: "Local-only model",
    note: "Still available to your own self-route requests; public traffic only reaches catalog models.",
  },
  "routing:model:model_weight_hash_mismatch": {
    kind: "command",
    label: "Re-download the model",
    command: "darkbloom models pull",
    note: "Local weights differ from the published build.",
  },
  "routing:model:model_template_render_broken": {
    kind: "command",
    label: "Re-download the model",
    command: "darkbloom models pull",
    note: "The chat template failed its render self-check, so every request shape is fenced away.",
  },
  "routing:model:model_requires_dedicated_box": {
    kind: "guidance",
    label: "Serve only this model",
    note: "Remove the other model families from `enabled_models` and restart, or accept that this build stays unrouted on a mixed box.",
  },
};

/**
 * Per-model warning ids embed the model id (`routing:model:<id>:<blocker>`)
 * so each row is distinct in the feed. Fixes are per-blocker, so strip the
 * model id before the lookup.
 */
function normalizeWarningId(warningId: string): string {
  const prefix = "routing:model:";
  if (!warningId.startsWith(prefix)) return warningId;
  const lastColon = warningId.lastIndexOf(":");
  if (lastColon <= prefix.length - 1) return warningId;
  return prefix + warningId.slice(lastColon + 1);
}

/** Safe fallback so an unmapped warning still points somewhere useful. */
export const GENERIC_FIX: FixAction = {
  kind: "link",
  label: "View setup guide",
  href: "/providers/setup",
};

/** Resolve a warning id to its fix, falling back to a generic link. */
export function resolveFix(warningId: string): FixAction {
  return FIX_TABLE[normalizeWarningId(warningId)] ?? GENERIC_FIX;
}

/** Whether a warning id has an explicit (non-fallback) fix. */
export function hasFix(warningId: string): boolean {
  return normalizeWarningId(warningId) in FIX_TABLE;
}

export { FIX_TABLE };
