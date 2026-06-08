import { describe, it, expect } from "vitest";
import { computeWarnings } from "@/app/providers/warnings";
import {
  deriveRouting,
  routingFor,
  routingMeta,
  selectTopWarning,
} from "@/app/providers/dashboard/routing";
import { baseProvider, ctx } from "./provider-dashboard-fixtures";

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
    expect(routingFor(baseProvider({ trust_level: "self_signed" }), ctx)).toBe("blocked");
  });

  it("returns blocked for untrusted status", () => {
    expect(routingFor(baseProvider({ status: "untrusted", failed_challenges: 3 }), ctx)).toBe("blocked");
  });

  it("returns degraded for an online machine with only degrading warnings", () => {
    const p = baseProvider({ mda_verified: false }); // mda_missing is degrading
    expect(routingFor(p, ctx)).toBe("degraded");
  });

  it("offline takes precedence over blocking warnings (still 'offline')", () => {
    const p = baseProvider({ status: "offline", online: false, trust_level: "self_signed" });
    expect(deriveRouting(p, computeWarnings(p, ctx))).toBe("offline");
  });
});

describe("routingMeta", () => {
  it("uses the load-bearing EARNING/NOT EARNING verbs", () => {
    expect(routingMeta("routable").verb).toContain("EARNING");
    expect(routingMeta("blocked").verb).toContain("NOT EARNING");
    expect(routingMeta("degraded").verb).toContain("EARNING");
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
    const p = baseProvider({ trust_level: "self_signed" });
    const top = selectTopWarning(computeWarnings(p, ctx));
    expect(top?.severity).toBe("blocking");
  });
});
