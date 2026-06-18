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
