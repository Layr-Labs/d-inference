// Measured throughput for one machine — the number behind the card's "Decode"
// line and the fleet-wide bar scale. Pure, so the card, the fleet max, and the
// tests all read one definition.
//
// The coordinator resolves `decode_tps` / `prefill_tps` from the heartbeat's
// per-slot EWMAs (registry.MeasuredThroughputLocked) and that value wins when
// present. The slot fallback below applies the same precedence client-side so a
// console deployed ahead of the coordinator still shows real numbers instead of
// "—": active model's slot first, then the fastest measured co-resident slot.
// A value of 0 means unmeasured and renders as an explicit blank.

import type { MyBackendSlot, MyProvider } from "../types";

export interface Throughput {
  decode: number;
  prefill: number;
}

function positive(v: number | undefined): number {
  return typeof v === "number" && Number.isFinite(v) && v > 0 ? v : 0;
}

function slotThroughput(slots: MyBackendSlot[] | undefined, currentModel: string | undefined): Throughput {
  const out: Throughput = { decode: 0, prefill: 0 };
  if (!slots?.length) return out;
  let bestDecode = 0;
  let bestPrefill = 0;
  for (const s of slots) {
    const decode = positive(s.observed_decode_tps);
    const prefill = positive(s.observed_prefill_tps);
    if (currentModel && s.model === currentModel) {
      out.decode = decode;
      out.prefill = prefill;
      continue;
    }
    if (decode > bestDecode) bestDecode = decode;
    if (prefill > bestPrefill) bestPrefill = prefill;
  }
  if (out.decode <= 0) out.decode = bestDecode;
  if (out.prefill <= 0) out.prefill = bestPrefill;
  return out;
}

/** Resolve a machine's measured decode/prefill tok/s (0 = unmeasured). */
export function resolveThroughput(provider: MyProvider): Throughput {
  const fromSlots = slotThroughput(provider.backend_capacity?.slots, provider.current_model);
  return {
    decode: positive(provider.decode_tps) || fromSlots.decode,
    prefill: positive(provider.prefill_tps) || fromSlots.prefill,
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
