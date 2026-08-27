import { describe, expect, it } from "vitest";
import {
  SUPPLY_SHED_REASONS,
  getMachineRecommendation,
  summarizeSupplyPressure,
  supplyLossRate,
  type SupplyPressureModel,
  type SupplySignalCounts,
} from "./supply-pressure";

const EMPTY_SIGNALS: SupplySignalCounts = {
  capacitySheds1h: 0,
  capacitySheds24h: 0,
  latencySheds1h: 0,
  latencySheds24h: 0,
  unavailableSheds1h: 0,
  unavailableSheds24h: 0,
  hardwareMismatches1h: 0,
  hardwareMismatches24h: 0,
};

function signals(overrides: Partial<SupplySignalCounts>): SupplySignalCounts {
  return { ...EMPTY_SIGNALS, ...overrides };
}

function model(
  overrides: Partial<SupplyPressureModel> & Pick<SupplyPressureModel, "model">,
): SupplyPressureModel {
  return {
    ...EMPTY_SIGNALS,
    displayName: overrides.model,
    minRamGB: null,
    unserved1h: 0,
    unserved24h: 0,
    served24h: 0,
    actualTTFTP95Ms1h: null,
    actualTTFTP95Ms24h: null,
    rejectedTTFTP95Ms1h: null,
    rejectedTTFTP95Ms24h: null,
    ...overrides,
  };
}

describe("supply rejection taxonomy", () => {
  it("tracks saturation, availability, and latency loss without request-shape failures", () => {
    expect(SUPPLY_SHED_REASONS).toEqual([
      "machine_busy",
      "queue_timeout",
      "queue_full",
      "ttft_too_slow",
      "first_chunk_timeout",
      "deadline_unreachable",
      "no_provider",
    ]);
    expect(SUPPLY_SHED_REASONS).not.toContain("model_too_large");
    expect(SUPPLY_SHED_REASONS).not.toContain("unservable_token_budget");
  });
});

describe("getMachineRecommendation", () => {
  it("uses active one-hour saturation ahead of older signals", () => {
    expect(
      getMachineRecommendation(
        signals({
          capacitySheds1h: 3,
          capacitySheds24h: 3,
          unavailableSheds24h: 100,
        }),
      ),
    ).toEqual({ kind: "add_machines", label: "Add machines", window: "1h" });
  });

  it("falls back to the dominant 24-hour signal", () => {
    expect(
      getMachineRecommendation(
        signals({
          capacitySheds24h: 2,
          latencySheds24h: 8,
          unavailableSheds24h: 1,
        }),
      ),
    ).toEqual({ kind: "warm_or_faster", label: "Warm / faster", window: "24h" });
  });

  it("distinguishes machines that are too small from too few machines", () => {
    expect(
      getMachineRecommendation(signals({ hardwareMismatches1h: 4 })),
    ).toEqual({ kind: "larger_machines", label: "Larger RAM", window: "1h" });
  });

  it("reports no shortage when no tracked signal exists", () => {
    expect(getMachineRecommendation(EMPTY_SIGNALS)).toEqual({
      kind: "none",
      label: "No shortage",
      window: null,
    });
  });
});

describe("supply pressure summary", () => {
  it("totals served and unserved demand and counts active models", () => {
    const summary = summarizeSupplyPressure([
      model({
        model: "model-a",
        unserved1h: 2,
        unserved24h: 5,
        served24h: 15,
        capacitySheds1h: 2,
      }),
      model({
        model: "model-b",
        unserved24h: 1,
        served24h: 4,
        hardwareMismatches1h: 1,
      }),
    ]);

    expect(summary).toEqual({
      unserved1h: 2,
      unserved24h: 6,
      served24h: 19,
      supplyLossRate24h: 0.24,
      pressuredModels1h: 2,
    });
  });

  it("returns no loss rate when there was no traffic", () => {
    expect(supplyLossRate(0, 0)).toBeNull();
    expect(supplyLossRate(2, 8)).toBe(0.2);
  });
});
