import { describe, it, expect } from "vitest";
import { fleetMaxDecodeTps, resolveThroughput } from "./throughput";
import { makeProvider } from "./testFixtures";
import type { MyBackendCapacity, MyBackendSlot } from "../types";

const ACTIVE = "qwen-27b";
const MOE = "qwen-35b-a3b";
const GEMMA = "gemma-26b";

function slot(model: string, decode?: number, prefill?: number): MyBackendSlot {
  return {
    model,
    state: "running",
    num_running: 0,
    num_waiting: 0,
    active_tokens: 0,
    max_tokens_potential: 8192,
    observed_decode_tps: decode,
    observed_prefill_tps: prefill,
  };
}

function capacity(slots: MyBackendSlot[]): MyBackendCapacity {
  return { slots, gpu_memory_active_gb: 38.1, gpu_memory_peak_gb: 40, gpu_memory_cache_gb: 1.6, total_memory_gb: 64 };
}

describe("resolveThroughput", () => {
  it("reads the active model's slot EWMA, unattributed, over a faster co-resident slot", () => {
    const p = makeProvider({
      decode_tps: 31.5,
      prefill_tps: 1400,
      current_model: ACTIVE,
      backend_capacity: capacity([slot(MOE, 92, 3100), slot(ACTIVE, 31.5, 1400)]),
    });
    expect(resolveThroughput(p)).toEqual({ decode: 31.5, prefill: 1400, decodeFallbackModel: undefined });
  });

  it("gives the same answer when an older coordinator omitted decode_tps", () => {
    const p = makeProvider({
      current_model: ACTIVE,
      backend_capacity: capacity([slot(MOE, 92, 3100), slot(ACTIVE, 31.5, 1400)]),
    });
    expect(resolveThroughput(p)).toMatchObject({ decode: 31.5, prefill: 1400 });
  });

  it("stands in the fastest measured co-resident slot, attributed, when the active model is unmeasured", () => {
    const p = makeProvider({
      decode_tps: 92,
      current_model: ACTIVE,
      backend_capacity: capacity([slot(ACTIVE), slot(GEMMA, 44, 900), slot(MOE, 92, 3100)]),
    });
    expect(resolveThroughput(p)).toEqual({ decode: 92, prefill: 3100, decodeFallbackModel: MOE });
  });

  it("attributes the stand-in when no model is active at all", () => {
    const p = makeProvider({ backend_capacity: capacity([slot(GEMMA, 44, 900), slot(ACTIVE, 31.5, 1400)]) });
    expect(resolveThroughput(p)).toEqual({ decode: 44, prefill: 1400, decodeFallbackModel: GEMMA });
  });

  it("resolves decode and prefill independently", () => {
    const p = makeProvider({
      current_model: ACTIVE,
      backend_capacity: capacity([slot(ACTIVE, 31.5), slot(GEMMA, 44, 900)]),
    });
    expect(resolveThroughput(p)).toEqual({ decode: 31.5, prefill: 900, decodeFallbackModel: undefined });
  });

  it("falls back to the coordinator's decode_tps / prefill_tps for a provider without slot EWMAs", () => {
    const legacy = makeProvider({ decode_tps: 60, prefill_tps: 700, current_model: ACTIVE, backend_capacity: capacity([slot(ACTIVE)]) });
    expect(resolveThroughput(legacy)).toEqual({ decode: 60, prefill: 700, decodeFallbackModel: undefined });
    const noCapacity = makeProvider({ decode_tps: 60, prefill_tps: 700 });
    expect(resolveThroughput(noCapacity)).toEqual({ decode: 60, prefill: 700, decodeFallbackModel: undefined });
  });

  it("reports 0 (unmeasured) for a connected machine that has not served yet", () => {
    const p = makeProvider({
      status: "online",
      online: true,
      current_model: ACTIVE,
      backend_capacity: capacity([slot(ACTIVE), slot(MOE)]),
    });
    expect(resolveThroughput(p)).toEqual({ decode: 0, prefill: 0, decodeFallbackModel: undefined });
  });

  it("reports 0 for an offline machine with no live snapshot", () => {
    expect(resolveThroughput(makeProvider({ status: "offline" }))).toMatchObject({ decode: 0, prefill: 0 });
  });

  it("ignores non-finite and non-positive wire values", () => {
    const p = makeProvider({
      decode_tps: Number.NaN,
      prefill_tps: -5,
      current_model: ACTIVE,
      backend_capacity: capacity([slot(ACTIVE, Number.POSITIVE_INFINITY, 0)]),
    });
    expect(resolveThroughput(p)).toEqual({ decode: 0, prefill: 0, decodeFallbackModel: undefined });
  });
});

describe("fleetMaxDecodeTps", () => {
  it("scales by the fastest resolved machine, whichever source it came from", () => {
    const fleet = [
      makeProvider({ id: "a", decode_tps: 31.5 }),
      makeProvider({ id: "b", current_model: "m", backend_capacity: capacity([slot("m", 92)]) }),
      makeProvider({ id: "c", status: "offline" }),
    ];
    expect(fleetMaxDecodeTps(fleet)).toBe(92);
  });

  it("is 0 for an unmeasured fleet", () => {
    expect(fleetMaxDecodeTps([makeProvider(), makeProvider({ id: "b" })])).toBe(0);
  });
});
