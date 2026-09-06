import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { expect, it } from "vitest";
import type { CapacityTelemetry } from "@/lib/telemetry-types";
import type { MyBackendCapacity } from "@/app/providers/types";

it("reads coherent process ownership from the canonical heartbeat fixture", () => {
  const wire = JSON.parse(readFileSync(resolve(process.cwd(),
    "../coordinator/protocol/testdata/process_memory_wire.json"), "utf8")) as CapacityTelemetry;
  const memory = wire.process_memory!;
  expect(memory.charged_bytes - memory.materialized_bytes).toBe(memory.unmaterialized_bytes);
  expect(memory.active_bytes + memory.cache_bytes + memory.unmaterialized_bytes).toBe(650);
  expect(memory.closing_owner_count).toBe(1);
  expect(memory.system_available_bytes).toBe(700);
  const capacity: MyBackendCapacity = { slots: [], gpu_memory_active_gb: 0,
    gpu_memory_peak_gb: 0, gpu_memory_cache_gb: 0, total_memory_gb: 0, telemetry: wire };
  expect(capacity.telemetry?.process_memory?.sample_seq).toBe(2);
});

it("keeps absent process telemetry distinct from a measured zero", () => {
  const legacy: CapacityTelemetry = JSON.parse("{}");
  expect(legacy.process_memory).toBeUndefined();
  const wire = JSON.parse(readFileSync(resolve(process.cwd(),
    "../coordinator/protocol/testdata/process_memory_wire.json"), "utf8")) as CapacityTelemetry;
  expect(wire.process_memory?.commitment_debt_bytes).toBe(0);
});
