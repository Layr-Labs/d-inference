// Renders the coordinator's routing verdict as dashboard warnings.
//
// Every gate here used to be re-derived client-side from a handful of exposed
// booleans, which could only ever approximate the real decision — and silently
// said nothing at all about the gates that were never exposed (SIP
// verification, privacy capabilities, code attestation, per-model weight-hash
// and template-render exclusions). A machine could be fenced by any of those
// while the dashboard showed a clean card.
//
// The coordinator now reports its own verdict on `MyProvider.routing`, so this
// module only has to translate it. No gate logic lives here.

import type { MyProvider, RoutingBlocker } from "./types";
import type { Warning, WarningSeverity } from "./warnings";

interface BlockerCopy {
  title: string;
  detail: string;
  severity?: WarningSeverity;
}

const BLOCKER_COPY: Record<RoutingBlocker, BlockerCopy> = {
  offline: {
    title: "Offline",
    detail:
      "The coordinator has no live connection to this machine. Start the provider with `darkbloom start`.",
  },
  untrusted: {
    title: "Marked untrusted by attestation",
    detail:
      "The coordinator rejected this machine's attestation and is not routing to it. Restart the provider and re-link the device.",
  },
  private_only: {
    title: "Private-only mode",
    detail:
      "This machine only serves your own self-route traffic, so it is not counted in the public catalog and does not earn from network requests.",
    severity: "info",
  },
  trust_below_minimum: {
    title: "Trust level below the routing threshold",
    detail:
      "The network requires hardware-attested machines. Complete MDM enrollment + Apple Device Attestation to start receiving requests.",
  },
  runtime_hash_mismatch: {
    title: "Runtime hash mismatch",
    detail:
      "This machine's runtime hashes match no registered release — most often a self-updated or partially-installed bundle. Reinstall with the official installer to restore eligibility.",
  },
  attestation_challenge_never_passed: {
    title: "Awaiting first attestation challenge",
    detail:
      "The machine is connected but has not completed a challenge handshake yet. Routing normally starts within ~5 minutes.",
    severity: "info",
  },
  attestation_challenge_stale: {
    title: "Attestation challenge stale",
    detail:
      "The last passing challenge is older than the freshness window, so the coordinator has dropped this machine from routing until a fresh handshake completes. Check that the Mac stays awake and the WebSocket is not being interrupted.",
  },
  no_encryption_key: {
    title: "No end-to-end encryption key published",
    detail:
      "The machine has not published an X25519 public key, so no request can be encrypted to it. Restart the provider.",
  },
  unsupported_backend: {
    title: "Inference backend no longer routable",
    detail:
      "This machine reports a retired inference backend. Reinstall with the latest installer.",
  },
  unencrypted_response_chunks: {
    title: "Response chunks are not encrypted",
    detail:
      "The machine did not advertise encrypted streaming chunks, which the network requires. Reinstall with the latest installer.",
  },
  runtime_manifest_unchecked: {
    title: "Runtime not verified against a release manifest",
    detail:
      "The coordinator could not match this machine's runtime to a registered release. Reinstall with the official installer.",
  },
  sip_unverified: {
    title: "System Integrity Protection not confirmed",
    detail:
      "The last attestation challenge did not confirm SIP. Re-enable SIP (`csrutil enable` from Recovery) and restart the provider.",
  },
  code_attestation_missing: {
    title: "Code-identity attestation incomplete",
    detail:
      "The machine has not completed the APNs code-identity handshake. Keep the Mac awake and reachable so the coordinator can complete it.",
  },
  privacy_capabilities_missing: {
    title: "Privacy capabilities not reported",
    detail:
      "The machine did not report its privacy capabilities, which the network requires before any prompt is routed to it. Reinstall with the latest installer.",
  },
  privacy_capabilities_incomplete: {
    title: "A required privacy capability is disabled",
    detail:
      "One of the required hardening capabilities (in-process backend, proxy disabled, anti-debug, core dumps disabled, scrubbed environment) is off. Restart the provider; if it persists, reinstall.",
  },
  no_models_registered: {
    title: "No models registered with the coordinator",
    detail:
      "This machine advertised an empty model list. Check that the weights finished downloading, that `enabled_models` is not filtering everything out, and that the model's architecture is supported by this provider version.",
  },
  no_routable_models: {
    title: "Every registered model was excluded",
    detail:
      "The machine registered models but none of them are routable. See the per-model reasons below.",
  },
  model_not_in_catalog: {
    title: "Model not in the published catalog",
    detail:
      "The coordinator does not publish this model, so public traffic is never routed to it. It remains available to your own self-route requests.",
    severity: "info",
  },
  model_weight_hash_mismatch: {
    title: "Model weight hash does not match the catalog",
    detail:
      "The local weights differ from the published build. Re-download the model with `darkbloom models pull` and restart the provider.",
  },
  model_template_render_broken: {
    title: "Chat template failed its render self-check",
    detail:
      "The provider could not render this model's chat template, so the coordinator fences every request shape away from it. Re-download the model.",
  },
  model_requires_dedicated_box: {
    title: "Model routes only to dedicated machines",
    detail:
      "This model is reserved for machines that serve nothing else, and this one also serves other model families. Restrict it to this model to receive that traffic.",
  },
};

function warningFor(
  blocker: RoutingBlocker,
  idPrefix: string,
  { suffix = "", severity }: { suffix?: string; severity?: WarningSeverity } = {}
): Warning {
  const copy = BLOCKER_COPY[blocker];
  if (!copy) {
    return {
      id: `${idPrefix}${blocker}`,
      severity: severity ?? "blocking",
      title: "Excluded from routing",
      detail: `The coordinator reported "${blocker}".`,
    };
  }
  return {
    id: `${idPrefix}${blocker}`,
    // An explicitly informational blocker stays informational; otherwise the
    // caller decides, because whether a model-level exclusion stops the
    // machine earning depends on the machine's other models.
    severity: copy.severity ?? severity ?? "blocking",
    title: copy.title + suffix,
    detail: copy.detail,
  };
}

/**
 * Warnings for a machine whose coordinator reported a routing verdict.
 * Returns null when the coordinator did not (older build), so the caller can
 * fall back to its local approximation.
 */
export function routingWarnings(p: MyProvider): Warning[] | null {
  const routing = p.routing;
  if (!routing) return null;

  const out: Warning[] = [];
  for (const blocker of routing.blockers ?? []) {
    out.push(warningFor(blocker, "routing:"));
  }

  // Per-model exclusions matter even when the machine itself is routable: one
  // stale build among several is exactly the case a machine-level verdict
  // hides. But they are NOT blocking while other builds still serve — a
  // machine that is earning must not render as "not earning" because a
  // catalog re-publish stranded one extra local build.
  const modelSeverity: WarningSeverity = routing.routable ? "degrading" : "blocking";
  const seen = new Set<string>();
  for (const model of routing.models ?? []) {
    for (const blocker of model.blockers ?? []) {
      const key = `${blocker}:${model.id}`;
      if (seen.has(key)) continue;
      seen.add(key);
      out.push(
        warningFor(blocker, `routing:model:${model.id}:`, {
          suffix: ` — ${model.id}`,
          severity: modelSeverity,
        })
      );
    }
  }
  return out;
}
