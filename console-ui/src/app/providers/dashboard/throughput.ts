// Measured throughput for one machine — the number behind the card's "Decode"
// line and the fleet-wide bar scale. Pure, so the card, the fleet max, and the
// tests all read one definition.
//
// Slot EWMAs are the raw measurement: retained by the provider across idle
// time (smoothed over recent requests, not decaying), so a value means
// "recently measured", not "decoding at this instant". Precedence mirrors the
// coordinator's registry.MeasuredThroughputLocked, which fills decode_tps /
// prefill_tps from the same slots: the active model's slot first, then the
// fastest measured co-resident slot (reported with its model so the card can
// say whose number it is), then the coordinator's value itself — which for a
// current provider is identical, and for a legacy provider without slot
// EWMAs is its registration benchmark. Resolving from slots first keeps the
// attribution and gives the same answer whichever side deploys first. 0 means
// unmeasured and renders as an explicit blank.

import type { MyBackendSlot, MyProvider } from "../types";

export interface Throughput {
  decode: number;
  prefill: number;
  /**
   * Model whose slot supplied `decode` when it is NOT the active model — the
   * active slot has no measurement yet (just swapped in, pre-warmed) and a
   * co-resident slot stands in. Undefined when the figure is the active
   * model's own, or when nothing is measured.
   */
  decodeFallbackModel?: string;
}

function positive(v: number | undefined): number {
  return typeof v === "number" && Number.isFinite(v) && v > 0 ? v : 0;
}

/** The slot with the largest positive reading, or undefined when none has one. */
function fastestSlot(slots: MyBackendSlot[], read: (s: MyBackendSlot) => number | undefined): MyBackendSlot | undefined {
  let best: MyBackendSlot | undefined;
  let bestValue = 0;
  for (const s of slots) {
    const v = positive(read(s));
    if (v > bestValue) {
      bestValue = v;
      best = s;
    }
  }
  return best;
}

function slotThroughput(slots: MyBackendSlot[] | undefined, currentModel: string | undefined): Throughput {
  if (!slots?.length) return { decode: 0, prefill: 0 };
  const active = currentModel ? slots.find((s) => s.model === currentModel) : undefined;
  const others = slots.filter((s) => s !== active);
  const out: Throughput = {
    decode: positive(active?.observed_decode_tps),
    prefill: positive(active?.observed_prefill_tps),
  };
  if (out.decode <= 0) {
    const standIn = fastestSlot(others, (s) => s.observed_decode_tps);
    if (standIn) {
      out.decode = positive(standIn.observed_decode_tps);
      out.decodeFallbackModel = standIn.model;
    }
  }
  if (out.prefill <= 0) {
    out.prefill = positive(fastestSlot(others, (s) => s.observed_prefill_tps)?.observed_prefill_tps);
  }
  return out;
}

/** Resolve a machine's measured decode/prefill tok/s (0 = unmeasured). */
export function resolveThroughput(provider: MyProvider): Throughput {
  const fromSlots = slotThroughput(provider.backend_capacity?.slots, provider.current_model);
  return {
    decode: fromSlots.decode || positive(provider.decode_tps),
    prefill: fromSlots.prefill || positive(provider.prefill_tps),
    decodeFallbackModel: fromSlots.decodeFallbackModel,
  };
}

/** Largest measured decode TPS across the fleet — scales the per-card bars. */
export function fleetMaxDecodeTps(providers: MyProvider[]): number {
  let max = 0;
  for (const p of providers) {
    const { decode } = resolveThroughput(p);
    if (decode > max) max = decode;
  }
  return max;
}
