import { describe, it, expect } from "vitest";
import { fleetMaxDecodeTps, resolveThroughput } from "./throughput";
import { makeProvider } from "./testFixtures";
import type { MyBackendCapacity, MyBackendSlot } from "../types";

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
  it("prefers the coordinator-resolved decode_tps / prefill_tps", () => {
    const p = makeProvider({
      decode_tps: 31.5,
      prefill_tps: 1400,
      current_model: "qwen-27b",
      backend_capacity: capacity([slot("qwen-35b-a3b", 92, 3100), slot("qwen-27b", 31.5, 1400)]),
    });
    expect(resolveThroughput(p)).toEqual({ decode: 31.5, prefill: 1400 });
  });

  it("falls back to the active model's slot EWMA when the coordinator omitted decode_tps", () => {
    const p = makeProvider({
      current_model: "qwen-27b",
      backend_capacity: capacity([slot("qwen-35b-a3b", 92, 3100), slot("qwen-27b", 31.5, 1400)]),
    });
    expect(resolveThroughput(p)).toEqual({ decode: 31.5, prefill: 1400 });
  });

  it("uses the fastest measured co-resident slot when the active model is unmeasured", () => {
    const p = makeProvider({
      current_model: "qwen-27b",
      backend_capacity: capacity([slot("qwen-27b"), slot("gemma-26b", 44, 900), slot("qwen-35b-a3b", 92, 3100)]),
    });
    expect(resolveThroughput(p)).toEqual({ decode: 92, prefill: 3100 });
  });

  it("resolves decode and prefill independently", () => {
    const p = makeProvider({
      current_model: "qwen-27b",
      backend_capacity: capacity([slot("qwen-27b", 31.5), slot("gemma-26b", 44, 900)]),
    });
    expect(resolveThroughput(p)).toEqual({ decode: 31.5, prefill: 900 });
  });

  it("reports 0 (unmeasured) for a connected machine that has not served yet", () => {
    const p = makeProvider({
      status: "online",
      online: true,
      current_model: "qwen-27b",
      backend_capacity: capacity([slot("qwen-27b"), slot("qwen-35b-a3b")]),
    });
    expect(resolveThroughput(p)).toEqual({ decode: 0, prefill: 0 });
  });

  it("reports 0 for an offline machine with no live snapshot", () => {
    expect(resolveThroughput(makeProvider({ status: "offline" }))).toEqual({ decode: 0, prefill: 0 });
  });

  it("ignores non-finite and non-positive wire values", () => {
    const p = makeProvider({
      decode_tps: Number.NaN,
      prefill_tps: -5,
      current_model: "qwen-27b",
      backend_capacity: capacity([slot("qwen-27b", Number.POSITIVE_INFINITY, 0)]),
    });
    expect(resolveThroughput(p)).toEqual({ decode: 0, prefill: 0 });
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
