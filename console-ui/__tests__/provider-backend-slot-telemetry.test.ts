import { describe, it, expect } from "vitest";
import type { MyBackendSlot } from "@/app/providers/types";

// TS mirror check for the measured provider telemetry fields added to the Go
// canonical BackendSlotCapacity (coordinator/protocol/messages.go) and the Swift
// mirror (provider-swift .../Protocol/Types.swift). The coordinator embeds the
// full protocol.BackendCapacity in /v1/me/providers, so these `omitempty` fields
// arrive as JSON only when measured/non-zero.
describe("MyBackendSlot measured telemetry mirror", () => {
  it("accepts observed_prefill_tps and model_load_time_ms (typed) and reads them back", () => {
    const slot: MyBackendSlot = {
      model: "mlx-community/Qwen2.5-7B-4bit",
      state: "running",
      num_running: 3,
      num_waiting: 1,
      active_tokens: 5000,
      max_tokens_potential: 12000,
      observed_prefill_tps: 412,
      model_load_time_ms: 9300,
    };
    expect(slot.observed_prefill_tps).toBe(412);
    expect(slot.model_load_time_ms).toBe(9300);
  });

  it("treats the measured fields as optional (omitted on the wire ↔ undefined)", () => {
    const raw = `{"model":"test","state":"running","num_running":2,"num_waiting":0,"active_tokens":3000,"max_tokens_potential":8000}`;
    const slot = JSON.parse(raw) as MyBackendSlot;
    expect(slot.observed_prefill_tps).toBeUndefined();
    expect(slot.model_load_time_ms).toBeUndefined();
  });
});

// The v0.8.0 paged-KV rollout discriminator. Go models it as `*string` with
// `omitempty`, so a non-nil pointer to "" is still emitted as `"kv_backend":""`
// while a pre-0.8.0 provider omits the key entirely. Those two must stay
// distinguishable here, or the rollout dashboard cannot tell "provider says
// nothing" from "provider says empty" — and, worse, would be free to fold both
// into "contiguous".
describe("MyBackendSlot kv_backend discriminator", () => {
  const base = `"model":"gemma-4-26b-qat-4bit","state":"running","num_running":1,"num_waiting":0,"active_tokens":100,"max_tokens_potential":400`;

  it("carries an explicit backend kind", () => {
    const slot = JSON.parse(`{${base},"kv_backend":"paged"}`) as MyBackendSlot;
    expect(slot.kv_backend).toBe("paged");
    expect("kv_backend" in slot).toBe(true);
  });

  it("is undefined when a pre-0.8.0 provider omits it (absent ⇒ unknown)", () => {
    const slot = JSON.parse(`{${base}}`) as MyBackendSlot;
    expect(slot.kv_backend).toBeUndefined();
    expect("kv_backend" in slot).toBe(false);
    // Absent is UNKNOWN. It must never read as an observation of either kind.
    expect(slot.kv_backend).not.toBe("contiguous");
    expect(slot.kv_backend).not.toBe("paged");
  });

  it("keeps an explicit empty value distinguishable from omission", () => {
    const explicit = JSON.parse(`{${base},"kv_backend":""}`) as MyBackendSlot;
    const omitted = JSON.parse(`{${base}}`) as MyBackendSlot;
    expect(explicit.kv_backend).toBe("");
    expect("kv_backend" in explicit).toBe(true);
    expect("kv_backend" in omitted).toBe(false);
    // The reason the Go side is a pointer and this side is optional: these two
    // slots are NOT the same observation.
    expect(explicit.kv_backend).not.toBe(omitted.kv_backend);
  });

  it("accepts both shipped kinds at the type level", () => {
    const slots: MyBackendSlot[] = (["paged", "contiguous"] as const).map((kind) => ({
      model: "gpt-oss-20b",
      state: "running",
      num_running: 0,
      num_waiting: 0,
      active_tokens: 0,
      max_tokens_potential: 0,
      kv_backend: kind,
    }));
    expect(slots.map((s) => s.kv_backend)).toEqual(["paged", "contiguous"]);
  });
});

// The other half of the pair. `kv_backend` alone cannot separate "the operator
// chose contiguous" from "this box could not build paged and degraded", and
// with `.auto` resolving paged as of v0.8.0 the second is the rollout's primary
// failure signal. Its ABSENCE RULE IS THE INVERSE of `kv_backend`'s, which is
// the part a reader gets wrong, so it is pinned here rather than left to the
// comment on the type.
describe("MyBackendSlot kv_backend_fallback_reason, read as a pair", () => {
  const base = `"model":"gemma-4-26b-qat-4bit","state":"running","num_running":1,"num_waiting":0,"active_tokens":100,"max_tokens_potential":400`;

  it("carries the provider's degrade reason verbatim", () => {
    const slot = JSON.parse(
      `{${base},"kv_backend":"contiguous","kv_backend_fallback_reason":"kernel_preflight: paged kernels unavailable"}`,
    ) as MyBackendSlot;
    expect(slot.kv_backend).toBe("contiguous");
    expect(slot.kv_backend_fallback_reason).toBe("kernel_preflight: paged kernels unavailable");
  });

  it("absent alongside a named backend is an authoritative NO DEGRADE", () => {
    const chose = JSON.parse(`{${base},"kv_backend":"contiguous"}`) as MyBackendSlot;
    expect(chose.kv_backend).toBe("contiguous");
    expect(chose.kv_backend_fallback_reason).toBeUndefined();
    expect("kv_backend_fallback_reason" in chose).toBe(false);
  });

  it("separates a deliberate contiguous from a degraded one — the whole point", () => {
    const chose = JSON.parse(`{${base},"kv_backend":"contiguous"}`) as MyBackendSlot;
    const fell = JSON.parse(
      `{${base},"kv_backend":"contiguous","kv_backend_fallback_reason":"kill_switch"}`,
    ) as MyBackendSlot;
    // Indistinguishable on the resolved kind alone...
    expect(chose.kv_backend).toBe(fell.kv_backend);
    // ...and distinguishable only through the pair.
    expect(chose.kv_backend_fallback_reason).not.toBe(fell.kv_backend_fallback_reason);
  });

  it("is unknown, not 'no degrade', when the slot named no backend at all", () => {
    // A pre-0.8.0 provider omits BOTH keys. Because the two ship together, an
    // absent reason may only be read as "did not degrade" when a kv_backend IS
    // present; here neither is, so nothing is known.
    const legacy = JSON.parse(`{${base}}`) as MyBackendSlot;
    expect(legacy.kv_backend).toBeUndefined();
    expect(legacy.kv_backend_fallback_reason).toBeUndefined();
    const known =
      legacy.kv_backend !== undefined
        ? legacy.kv_backend_fallback_reason === undefined
          ? "no-degrade"
          : "degraded"
        : "unknown";
    expect(known).toBe("unknown");
  });

  it("every live degrade class round-trips as an opaque string", () => {
    // Not a union type on purpose: the leading class token is bounded, but the
    // trailing detail is untrusted provider free text.
    for (const reason of [
      "kill_switch",
      "kernel_preflight: MTLLibrary not found",
      "physical_capacity: needed 12 GiB, available 4 GiB",
      "ineligible: vlm",
      "pool_construction_capacity: 0 pages",
    ]) {
      const slot = JSON.parse(
        `{${base},"kv_backend":"contiguous","kv_backend_fallback_reason":${JSON.stringify(reason)}}`,
      ) as MyBackendSlot;
      expect(slot.kv_backend_fallback_reason).toBe(reason);
    }
  });
});
