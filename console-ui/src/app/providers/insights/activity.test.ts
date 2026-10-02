import { describe, it, expect } from "vitest";
import { modelActivity, tokenProgress } from "./activity";
import { makeProvider } from "../dashboard/testFixtures";
import type { MyBackendCapacity } from "../types";

const now = Date.parse("2026-10-01T12:00:00Z");
const cap: MyBackendCapacity = { gpu_memory_active_gb: 1, gpu_memory_cache_gb: 0, gpu_memory_peak_gb: 1, total_memory_gb: 64, slots: [{ model: "qwen", state: "running", num_running: 3, num_waiting: 1, active_tokens: 40, max_tokens_potential: 100 }] };
describe("observed model activity", () => {
  it("aggregates only fresh online running and idle slots, not stale or crashed work", () => {
    const providers = [
      makeProvider({ id: "one", online: true, capacity_accepted_at: new Date(now).toISOString(), backend_capacity: cap }),
      makeProvider({ id: "two", online: true, capacity_accepted_at: new Date(now).toISOString(), backend_capacity: cap }),
      makeProvider({ id: "stale", online: true, capacity_accepted_at: new Date(now - 91_000).toISOString(), backend_capacity: cap }),
      makeProvider({ id: "offline", online: false, backend_capacity: cap }),
      makeProvider({ id: "crashed", online: true, capacity_accepted_at: new Date(now).toISOString(), backend_capacity: { ...cap, slots: [{ ...cap.slots[0], state: "crashed" }] } }),
    ];
    expect(modelActivity(providers, now, 90)).toEqual({ models: [{ model: "qwen", running: 6, waiting: 2, machines: ["one", "two"] }], unknown: 1 });
  });
  it("treats missing capacity as unknown and never turns a load into running work", () => {
    expect(modelActivity([makeProvider({ online: true })], now, 90)).toEqual({ models: [], unknown: 1 });
  });
});
describe("token milestones", () => {
  it("moves to the next milestone at the exact boundary and caps the final tier", () => {
    expect(tokenProgress(99_999).next).toBe(100_000);
    expect(tokenProgress(100_000)).toMatchObject({ previous: 100_000, next: 1_000_000, progress: 0 });
    expect(tokenProgress(1_000_000_000_001)).toMatchObject({ next: null, progress: 100 });
    expect(tokenProgress(0).achieved).toEqual([]);
  });
});
