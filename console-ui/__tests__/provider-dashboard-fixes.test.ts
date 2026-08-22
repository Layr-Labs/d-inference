import { describe, it, expect } from "vitest";
import { computeWarnings } from "@/app/providers/warnings";
import { resolveFix, hasFix, GENERIC_FIX, FIX_TABLE } from "@/app/providers/dashboard/fixes";
import { baseProvider, ctx } from "./provider-dashboard-fixtures";
import type { MyProvider } from "@/app/providers/types";

const crashedSlot = {
  model: "m",
  state: "crashed" as const,
  num_running: 0,
  num_waiting: 0,
  active_tokens: 0,
  max_tokens_potential: 0,
};
const idleSlot = { ...crashedSlot, state: "idle_shutdown" as const };

// Scenarios that, together, trigger every warning id computeWarnings() emits.
const scenarios: { p: MyProvider; ctxOverride?: typeof ctx }[] = [
  { p: baseProvider({ status: "untrusted", failed_challenges: 3 }) },
  { p: baseProvider({ status: "offline", online: false }) },
  { p: baseProvider({ status: "never_seen", online: false }) },
  { p: baseProvider({ runtime_verified: false }) },
  { p: baseProvider({ version: "0.1.0" }), ctxOverride: { ...ctx, min_provider_version: "0.5.16" } },
  { p: baseProvider({ system_metrics: { memory_pressure: 0.2, cpu_usage: 0.2, thermal_state: "critical" } }) },
  { p: baseProvider({ last_challenge_verified: new Date(Date.now() - 11 * 60 * 1000).toISOString() }) },
  { p: baseProvider({ trust_level: "self_signed" }) },
  { p: baseProvider({ trust_level: "none", mda_verified: false }) },
  {
    p: baseProvider({
      backend_capacity: { slots: [crashedSlot], gpu_memory_active_gb: 0, gpu_memory_peak_gb: 0, gpu_memory_cache_gb: 0, total_memory_gb: 64 },
    }),
  },
  { p: baseProvider({ mda_verified: false }) },
  { p: baseProvider({ system_metrics: { memory_pressure: 0.2, cpu_usage: 0.2, thermal_state: "serious" } }) },
  { p: baseProvider({ system_metrics: { memory_pressure: 0.2, cpu_usage: 0.2, thermal_state: "fair" } }) },
  { p: baseProvider({ system_metrics: { memory_pressure: 0.95, cpu_usage: 0.2, thermal_state: "nominal" } }) },
  {
    p: baseProvider({
      backend_capacity: { slots: [idleSlot], gpu_memory_active_gb: 0, gpu_memory_peak_gb: 0, gpu_memory_cache_gb: 0, total_memory_gb: 64 },
    }),
  },
  {
    p: baseProvider({
      reputation: {
        score: 0.3, total_jobs: 20, successful_jobs: 10, failed_jobs: 10,
        total_uptime_seconds: 100, avg_response_time_ms: 500, challenges_passed: 5, challenges_failed: 0,
      },
    }),
  },
  { p: baseProvider({ models: [] }) },
  { p: baseProvider({ account_id: "", wallet_address: undefined }) },
  { p: baseProvider({ version: "0.5.10" }), ctxOverride: { ...ctx, latest_provider_version: "0.5.16", min_provider_version: "0.5.0" } },
  { p: baseProvider({ last_challenge_verified: undefined }) },
];

describe("fixes ↔ warnings contract", () => {
  // Collect every warning id the engine can emit from our scenario matrix.
  const ids = new Set<string>();
  for (const { p, ctxOverride } of scenarios) {
    for (const w of computeWarnings(p, ctxOverride ?? ctx)) ids.add(w.id);
  }

  it("triggers a broad set of warning ids (sanity)", () => {
    // Guards against the scenario matrix silently going stale.
    expect(ids.size).toBeGreaterThanOrEqual(18);
  });

  it("has an explicit fix for EVERY warning id the engine emits", () => {
    const missing = [...ids].filter((id) => !hasFix(id));
    expect(missing).toEqual([]);
  });

  it("every fix has a usable action payload", () => {
    for (const [id, fix] of Object.entries(FIX_TABLE)) {
      expect(fix.label, id).toBeTruthy();
      if (fix.kind === "command") expect(fix.command, id).toBeTruthy();
      if (fix.kind === "link") expect(fix.href, id).toBeTruthy();
    }
  });

  it("falls back to the generic fix for an unknown id", () => {
    expect(resolveFix("totally-unknown-warning")).toBe(GENERIC_FIX);
    expect(hasFix("totally-unknown-warning")).toBe(false);
  });

  // The coordinator ranks providers by additive cost in milliseconds
  // (coordinator/registry/scheduler.go). It has no multiplicative "health
  // factor" or "routing weight" — that scoring model was removed, but the
  // dashboard kept quoting it ("0.8x health", "caps health to 0.1x", "health
  // factor is zero", "losing routing weight"), which told operators their
  // machine was losing traffic it was not losing. Pin the copy so the deleted
  // model cannot describe the live one again. Both orderings matter: the
  // multiplier led in some strings and trailed in others.
  const DEAD_SCORING_MODEL = [
    /\d+(\.\d+)?\s*x\b/i, // 0.8x, 0.05x, 10 x
    /\bhealth\s+factor\b/i,
    /\brouting\s+weight\b/i,
    /\bhealth\s+(?:multiplier|score)\b/i,
    /\bcaps?\s+health\b/i,
  ];

  const usesDeadScoringModel = (text: string) =>
    DEAD_SCORING_MODEL.some((re) => re.test(text));

  it("never describes routing with multiplicative weights", () => {
    const offenders: string[] = [];

    for (const { p, ctxOverride } of scenarios) {
      for (const w of computeWarnings(p, ctxOverride ?? ctx)) {
        if (usesDeadScoringModel(w.title) || usesDeadScoringModel(w.detail)) {
          offenders.push(`warning ${w.id}`);
        }
      }
    }
    for (const [id, fix] of Object.entries(FIX_TABLE)) {
      if (usesDeadScoringModel(fix.label) || usesDeadScoringModel(fix.note ?? "")) {
        offenders.push(`fix ${id}`);
      }
    }

    expect(offenders).toEqual([]);
  });

  // Guard the guard: every string this change removed must actually trip it.
  it("the multiplicative-weight guard catches every string it replaced", () => {
    const removed = [
      "Thermal state fair (0.8x health)",
      "Thermal state serious (0.4x health)",
      "Backend crashed (0.05x routing weight)",
      "Backend cold (0.1x weight on cold start)",
      "95% memory pressure caps health to 0.1x. Close other apps or upgrade RAM.",
      "Close other apps (or add RAM) — high pressure caps health to 0.1x.",
      "Health factor is zero; the coordinator will not route work.",
      "The system is throttling and losing routing weight.",
      "Backend(s) report a crashed state and score 0.05x.",
    ];
    expect(removed.filter((s) => !usesDeadScoringModel(s))).toEqual([]);
  });
});
