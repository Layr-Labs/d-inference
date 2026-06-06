import { describe, it, expect } from "vitest";
import {
  buildAttentionGroups,
  deriveFleetVerdict,
  capacitySegments,
  fleetMaxDecodeTps,
  fleetDecodeTps,
  onlineCount,
} from "@/app/providers/dashboard/aggregate";
import { baseProvider, ctx } from "./provider-dashboard-fixtures";

describe("buildAttentionGroups", () => {
  it("dedupes the same warning across machines into one group", () => {
    const groups = buildAttentionGroups(
      [
        baseProvider({ id: "a", mda_verified: false }),
        baseProvider({ id: "b", mda_verified: false }),
      ],
      ctx
    );
    const mda = groups.find((g) => g.id === "mda_missing");
    expect(mda).toBeDefined();
    expect(mda?.providers.map((p) => p.id).sort()).toEqual(["a", "b"]);
  });

  it("ranks blocking before degrading, then by affected-machine count", () => {
    const groups = buildAttentionGroups(
      [
        baseProvider({ id: "a", trust_level: "self_signed" }), // blocking
        baseProvider({ id: "b", mda_verified: false }), // degrading
        baseProvider({ id: "c", mda_verified: false }), // degrading
      ],
      ctx
    );
    expect(groups[0].severity).toBe("blocking");
    // degrading group covers 2 machines
    const deg = groups.find((g) => g.severity === "degrading");
    expect(deg?.providers.length).toBe(2);
  });

  it("attaches a fix to every group", () => {
    const groups = buildAttentionGroups([baseProvider({ runtime_verified: false })], ctx);
    expect(groups.every((g) => Boolean(g.fix?.label))).toBe(true);
  });

  it("returns no groups for a fully healthy fleet", () => {
    expect(buildAttentionGroups([baseProvider(), baseProvider({ id: "x" })], ctx)).toEqual([]);
  });
});

describe("deriveFleetVerdict", () => {
  it("is routable + 'Everything's earning' when all machines are healthy", () => {
    const v = deriveFleetVerdict([baseProvider(), baseProvider({ id: "x" })], ctx);
    expect(v.state).toBe("routable");
    expect(v.counts.routable).toBe(2);
    expect(v.headline).toMatch(/earning/i);
  });

  it("escalates to blocked when any machine is blocked", () => {
    const v = deriveFleetVerdict(
      [baseProvider(), baseProvider({ id: "x", trust_level: "self_signed" })],
      ctx
    );
    expect(v.state).toBe("blocked");
    expect(v.counts.blocked).toBe(1);
    expect(v.counts.routable).toBe(1);
  });

  it("never shows a false all-clear for a degraded fleet", () => {
    const providers = [baseProvider({ mda_verified: false })];
    const v = deriveFleetVerdict(providers, ctx);
    expect(v.state).toBe("degraded");
    expect(v.state).not.toBe("routable");
    expect(buildAttentionGroups(providers, ctx).length).toBeGreaterThan(0);
  });

  it("reports the all-offline fleet", () => {
    const v = deriveFleetVerdict(
      [baseProvider({ status: "offline", online: false }), baseProvider({ id: "x", status: "never_seen", online: false })],
      ctx
    );
    expect(v.state).toBe("offline");
    expect(v.counts.offline).toBe(2);
    expect(v.headline).toMatch(/offline/i);
  });

  it("handles an empty fleet without throwing", () => {
    const v = deriveFleetVerdict([], ctx);
    expect(v.counts.total).toBe(0);
    expect(v.state).toBe("routable");
  });
});

describe("capacitySegments", () => {
  it("only includes non-zero segments", () => {
    const v = deriveFleetVerdict([baseProvider()], ctx);
    const segs = capacitySegments(v.counts);
    expect(segs.length).toBe(1);
    expect(segs[0].state).toBe("routable");
  });
});

describe("fleet throughput + online helpers", () => {
  it("computes max/sum decode tps with guards", () => {
    const providers = [
      baseProvider({ decode_tps: 40 }),
      baseProvider({ id: "x", decode_tps: 90 }),
      baseProvider({ id: "y", decode_tps: undefined }),
    ];
    expect(fleetMaxDecodeTps(providers)).toBe(90);
    expect(fleetDecodeTps(providers)).toBe(130);
    expect(fleetMaxDecodeTps([])).toBe(0);
  });

  it("counts only connected machines as online", () => {
    const providers = [
      baseProvider({ status: "serving" }),
      baseProvider({ id: "x", status: "online" }),
      baseProvider({ id: "y", status: "offline", online: false }),
    ];
    expect(onlineCount(providers)).toBe(2);
  });
});
