import { describe, it, expect } from "vitest";
import { computeWarnings } from "@/app/providers/warnings";
import {
  deriveRouting,
  routingFor,
  routingMeta,
  selectTopWarning,
} from "@/app/providers/dashboard/routing";
import { baseProvider, ctx, serviceStatus } from "./provider-dashboard-fixtures";

describe("deriveRouting", () => {
  it("returns routable for a perfectly healthy machine", () => {
    expect(routingFor(baseProvider(), ctx)).toBe("routable");
  });

  it("returns offline for offline/never_seen regardless of warnings", () => {
    expect(routingFor(baseProvider({ status: "offline", online: false }), ctx)).toBe("offline");
    expect(routingFor(baseProvider({ status: "never_seen", online: false }), ctx)).toBe("offline");
  });

  it("returns blocked for an online machine with a blocking warning", () => {
    // self-signed trust is blocking in production (min trust = hardware)
    expect(routingFor(baseProvider({ trust_level: "self_signed", service_status: serviceStatus({ state: "unavailable", reason: "trust_floor" }) }), ctx)).toBe("blocked");
  });

  it("returns blocked for untrusted status", () => {
    expect(routingFor(baseProvider({ status: "untrusted", failed_challenges: 3, service_status: serviceStatus({ state: "unavailable", reason: "untrusted" }) }), ctx)).toBe("blocked");
  });

  it("returns degraded for an online machine with only degrading warnings", () => {
    const p = baseProvider({ service_status: serviceStatus({state: "limited"}), system_metrics: { memory_pressure: 0.2, cpu_usage: 0.1, thermal_state: "serious" } }); // thermal_serious is degrading
    expect(routingFor(p, ctx)).toBe("degraded");
  });

  it("offline takes precedence over blocking warnings (still 'offline')", () => {
    const p = baseProvider({ status: "offline", online: false, trust_level: "self_signed" });
    expect(deriveRouting(p, computeWarnings(p, ctx))).toBe("offline");
  });
});

describe("authoritative routing status", () => {
  it("does not turn a historical low success warning into reduced priority", () => {
    const p = baseProvider({ reputation: { score: 0.4, total_jobs: 100, successful_jobs: 20, failed_jobs: 80, total_uptime_seconds: 100, avg_response_time_ms: 500, challenges_passed: 1, challenges_failed: 0 } });
    expect(computeWarnings(p, ctx).some(w => w.id === "low_success_rate")).toBe(true);
    expect(routingFor(p, ctx)).toBe("routable");
  });
  it("does not invent eligibility for old or stale API responses", () => {
    expect(routingFor(baseProvider({ service_status: undefined }), ctx)).toBe("unknown");
    expect(routingFor(baseProvider({ service_status: serviceStatus({ expires_at: new Date(Date.now() - 1).toISOString() }) }), ctx)).toBe("unknown");
  });
});

describe("routingMeta", () => {
  it("describes eligibility without claiming traffic or earnings", () => {
    expect(routingMeta("routable").verb).toContain("Ready");
    expect(routingMeta("blocked").verb).toContain("restricted");
    expect(routingMeta("degraded").verb).toContain("limited");
    expect(routingMeta("offline").verb).toContain("OFFLINE");
  });

  it("maps each state to a distinct rail color", () => {
    const rails = (["routable", "degraded", "blocked", "offline"] as const).map((s) => routingMeta(s).rail);
    expect(new Set(rails).size).toBe(4);
  });
});

describe("selectTopWarning", () => {
  it("returns null for no warnings", () => {
    expect(selectTopWarning([])).toBeNull();
  });

  it("prefers blocking over degrading over info", () => {
    const w = selectTopWarning([
      { id: "i", severity: "info", title: "info", detail: "" },
      { id: "d", severity: "degrading", title: "deg", detail: "" },
      { id: "b", severity: "blocking", title: "block", detail: "" },
    ]);
    expect(w?.id).toBe("b");
  });

  it("returns the highest-severity real warning for a blocked machine", () => {
    const p = baseProvider({ trust_level: "self_signed", service_status: serviceStatus({ state: "unavailable", reason: "trust_floor" }) });
    const top = selectTopWarning(computeWarnings(p, ctx));
    expect(top?.severity).toBe("blocking");
  });
});
