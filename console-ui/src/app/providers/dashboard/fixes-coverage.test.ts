import { describe, expect, it } from "vitest";

import { routingWarnings } from "../routing-blockers";
import type { RoutingBlocker } from "../types";
import { hasFix, resolveFix } from "./fixes";
import { makeProvider, makeRouting } from "./testFixtures";

// fixes.ts states the invariant "every warning id produced by computeWarnings()
// must have an entry here" but the test enforcing it never existed. This is it,
// for the routing verdict — the one warning family whose ids are generated
// rather than hand-written, and therefore the one that can silently grow past
// the fix table.

const MACHINE_BLOCKERS: RoutingBlocker[] = [
  "offline",
  "untrusted",
  "private_only",
  "trust_below_minimum",
  "runtime_hash_mismatch",
  "attestation_challenge_never_passed",
  "attestation_challenge_stale",
  "no_encryption_key",
  "unsupported_backend",
  "unencrypted_response_chunks",
  "runtime_manifest_unchecked",
  "sip_unverified",
  "code_attestation_missing",
  "privacy_capabilities_missing",
  "privacy_capabilities_incomplete",
  "no_models_registered",
  "no_routable_models",
];

const MODEL_BLOCKERS: RoutingBlocker[] = [
  "model_not_in_catalog",
  "model_weight_hash_mismatch",
  "model_template_render_broken",
];

describe("every routing blocker is actionable", () => {
  it.each(MACHINE_BLOCKERS)("machine blocker %s has an explicit fix", (blocker) => {
    const p = makeProvider({
      status: "serving",
      online: true,
      routing: makeRouting({ routable: false, blockers: [blocker], models: [] }),
    });
    const warnings = routingWarnings(p)!;
    expect(warnings).toHaveLength(1);
    expect(hasFix(warnings[0].id)).toBe(true);
  });

  it.each(MODEL_BLOCKERS)("model blocker %s has an explicit fix", (blocker) => {
    const p = makeProvider({
      status: "serving",
      online: true,
      routing: makeRouting({
        models: [
          {
            id: "some/model-with:colons",
            publicly_listed: false,
            owner_routable: false,
            blockers: [blocker],
          },
        ],
      }),
    });
    const warnings = routingWarnings(p)!;
    expect(warnings).toHaveLength(1);
    // Model ids can contain colons; the fix lookup must still resolve.
    expect(hasFix(warnings[0].id)).toBe(true);
    expect(resolveFix(warnings[0].id).label).not.toBe("View setup guide");
  });

  it("falls back to the generic fix for an id it has never seen", () => {
    expect(resolveFix("routing:some_future_blocker").label).toBe("View setup guide");
  });
});
