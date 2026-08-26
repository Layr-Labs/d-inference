import { describe, expect, it } from "vitest";

import { routingWarnings } from "../routing-blockers";
import { computeWarnings } from "../warnings";
import { deriveRouting } from "./routing";
import { makeProvider, makeRouting } from "./testFixtures";

const ctx = {
  latest_provider_version: "0.8.9",
  min_provider_version: "0.8.0",
  heartbeat_timeout_seconds: 90,
  challenge_max_age_seconds: 360,
};

const serving = {
  status: "serving" as const,
  online: true,
  version: "0.8.9",
  models: [{ id: "gemma-4-26b-qat-4bit" }],
};

describe("coordinator routing verdict", () => {
  it("produces no routing warnings for a healthy machine", () => {
    const p = makeProvider({ ...serving, routing: makeRouting() });
    expect(routingWarnings(p)).toEqual([]);
    expect(deriveRouting(p, computeWarnings(p, ctx))).toBe("routable");
  });

  it("returns null when the coordinator reported no verdict, so the caller falls back", () => {
    expect(routingWarnings(makeProvider(serving))).toBeNull();
  });

  it("surfaces gates the old dashboard could not see at all", () => {
    for (const blocker of [
      "sip_unverified",
      "privacy_capabilities_incomplete",
      "code_attestation_missing",
      "runtime_manifest_unchecked",
      "unencrypted_response_chunks",
    ] as const) {
      const p = makeProvider({
        ...serving,
        routing: makeRouting({ routable: false, blockers: [blocker] }),
      });
      const warnings = computeWarnings(p, ctx);
      const found = warnings.find((w) => w.id === `routing:${blocker}`);
      expect(found, blocker).toBeTruthy();
      expect(found!.severity).toBe("blocking");
      expect(found!.detail.length).toBeGreaterThan(20);
      expect(deriveRouting(p, warnings)).toBe("blocked");
    }
  });

  it("reports an empty model list as its own distinct reason", () => {
    const p = makeProvider({
      ...serving,
      models: [],
      routing: makeRouting({
        advertising: false,
        routable: false,
        owner_routable: false,
        blockers: ["no_models_registered"],
        models: [],
      }),
    });
    const warnings = computeWarnings(p, ctx);
    expect(warnings.some((w) => w.id === "routing:no_models_registered")).toBe(true);
    // The legacy client-side guess must not also fire.
    expect(warnings.some((w) => w.id === "no_catalog_models")).toBe(false);
  });

  it("keeps an earning machine earning when one extra build is stranded", () => {
    // A catalog re-publish is enough to strand a local build. Rendering the
    // whole card as "not earning" for that would contradict the very verdict
    // this module exists to trust.
    const p = makeProvider({
      ...serving,
      routing: makeRouting({
        models: [
          { id: "good-build", publicly_listed: true, routable: true, owner_routable: true },
          {
            id: "stale-build",
            publicly_listed: false,
            routable: false,
            owner_routable: false,
            blockers: ["model_weight_hash_mismatch"],
          },
        ],
      }),
    });
    const warnings = computeWarnings(p, ctx);
    const stranded = warnings.find(
      (w) => w.id === "routing:model:stale-build:model_weight_hash_mismatch"
    );
    expect(stranded!.severity).toBe("degrading");
    expect(deriveRouting(p, warnings)).not.toBe("blocked");
  });

  it("escalates per-model exclusions to blocking when nothing is routable", () => {
    const p = makeProvider({
      ...serving,
      routing: makeRouting({
        advertising: false,
        routable: false,
        owner_routable: false,
        blockers: ["no_routable_models"],
        models: [
          {
            id: "stale-build",
            publicly_listed: false,
            routable: false,
            owner_routable: false,
            blockers: ["model_weight_hash_mismatch"],
          },
        ],
      }),
    });
    const warnings = computeWarnings(p, ctx);
    const stranded = warnings.find(
      (w) => w.id === "routing:model:stale-build:model_weight_hash_mismatch"
    );
    expect(stranded!.severity).toBe("blocking");
    expect(deriveRouting(p, warnings)).toBe("blocked");
  });

  it("reports a dedicated-box exclusion with the model named", () => {
    const p = makeProvider({
      ...serving,
      routing: makeRouting({
        models: [
          { id: "gpt-oss-20b", publicly_listed: true, routable: true, owner_routable: true },
          {
            id: "gemma-4-26b-qat-4bit",
            publicly_listed: true,
            routable: false,
            owner_routable: true,
            blockers: ["model_requires_dedicated_box"],
          },
        ],
      }),
    });
    const warning = computeWarnings(p, ctx).find(
      (w) => w.id === "routing:model:gemma-4-26b-qat-4bit:model_requires_dedicated_box"
    );
    expect(warning).toBeTruthy();
    expect(warning!.title).toContain("gemma-4-26b-qat-4bit");
  });

  it("reports per-model exclusions even when the machine itself is routable", () => {
    const p = makeProvider({
      ...serving,
      routing: makeRouting({
        models: [
          { id: "good-build", publicly_listed: true, routable: true, owner_routable: true },
          {
            id: "stale-build",
            publicly_listed: false,
            routable: false,
            owner_routable: false,
            blockers: ["model_weight_hash_mismatch"],
          },
        ],
      }),
    });
    const warnings = computeWarnings(p, ctx);
    const modelWarning = warnings.find(
      (w) => w.id === "routing:model:stale-build:model_weight_hash_mismatch"
    );
    expect(modelWarning).toBeTruthy();
    expect(modelWarning!.title).toContain("stale-build");
  });

  it("treats an off-catalog local model as informational, not blocking", () => {
    const p = makeProvider({
      ...serving,
      routing: makeRouting({
        models: [
          {
            id: "my-local-build",
            publicly_listed: false,
            routable: false,
            owner_routable: true,
            blockers: ["model_not_in_catalog"],
          },
        ],
      }),
    });
    const warnings = computeWarnings(p, ctx);
    const w = warnings.find(
      (x) => x.id === "routing:model:my-local-build:model_not_in_catalog"
    );
    expect(w!.severity).toBe("info");
    expect(deriveRouting(p, warnings)).not.toBe("blocked");
  });

  it("does not duplicate the offline warning for an offline machine", () => {
    const p = makeProvider({
      status: "offline",
      online: false,
      routing: makeRouting({
        advertising: false,
        routable: false,
        owner_routable: false,
        blockers: ["offline"],
        models: [],
      }),
    });
    const warnings = computeWarnings(p, ctx);
    expect(warnings.filter((w) => w.title.toLowerCase().includes("offline"))).toHaveLength(1);
  });

  it("prefers the version remedy over the generic hash remedy below the floor", () => {
    // The coordinator clears BOTH runtime flags for a below-floor machine, so
    // both blockers arrive and both are red herrings.
    const p = makeProvider({
      ...serving,
      version: "0.7.0",
      routing: makeRouting({
        routable: false,
        blockers: ["runtime_hash_mismatch", "runtime_manifest_unchecked"],
      }),
    });
    const warnings = computeWarnings(p, ctx);
    expect(warnings.some((w) => w.id === "version_below_min")).toBe(true);
    expect(warnings.some((w) => w.id === "routing:runtime_hash_mismatch")).toBe(false);
    expect(warnings.some((w) => w.id === "routing:runtime_manifest_unchecked")).toBe(false);
  });

  it("still reports the hash mismatch when the version is current", () => {
    const p = makeProvider({
      ...serving,
      routing: makeRouting({ routable: false, blockers: ["runtime_hash_mismatch"] }),
    });
    expect(
      computeWarnings(p, ctx).some((w) => w.id === "routing:runtime_hash_mismatch")
    ).toBe(true);
  });
});

describe("legacy fallback (coordinator without a routing verdict)", () => {
  it("keeps reporting the four gates the old response exposed", () => {
    const p = makeProvider({
      status: "serving",
      online: true,
      version: "0.8.9",
      runtime_verified: false,
      trust_level: "self_signed",
      models: [],
      last_challenge_verified: new Date(Date.now() - 60 * 60 * 1000).toISOString(),
    });
    const ids = computeWarnings(p, ctx).map((w) => w.id);
    expect(ids).toContain("runtime_unverified");
    expect(ids).toContain("challenge_stale");
    expect(ids).toContain("trust_self_signed");
    expect(ids).toContain("no_catalog_models");
  });
});
