import { describe, expect, it } from "vitest";
import {
  SUPPLY_SHED_REASONS,
  getDominantSupplySignal,
  summarizeSupplyPressure,
  supplyRejectShare,
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
    supplyRejects1h: 0,
    supplyRejects24h: 0,
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
      "capacity_exhausted",
      "ttft_too_slow",
      "first_chunk_timeout",
      "deadline_unreachable",
      "no_provider",
    ]);
    expect(SUPPLY_SHED_REASONS).not.toContain("model_too_large");
    expect(SUPPLY_SHED_REASONS).not.toContain("unservable_token_budget");
  });
});

describe("getDominantSupplySignal", () => {
  it("uses active one-hour saturation ahead of older signals", () => {
    expect(
      getDominantSupplySignal(
        signals({
          capacitySheds1h: 3,
          capacitySheds24h: 3,
          unavailableSheds24h: 100,
        }),
      ),
    ).toEqual({ kind: "capacity", label: "Capacity rejects", window: "1h" });
  });

  it("falls back to the dominant 24-hour signal", () => {
    expect(
      getDominantSupplySignal(
        signals({
          capacitySheds24h: 2,
          latencySheds24h: 8,
          unavailableSheds24h: 1,
        }),
      ),
    ).toEqual({ kind: "latency", label: "TTFT / deadline rejects", window: "24h" });
  });

  it("distinguishes machines that are too small from too few machines", () => {
    expect(
      getDominantSupplySignal(signals({ hardwareMismatches1h: 4 })),
    ).toEqual({ kind: "hardware_mismatch", label: "Needs larger RAM", window: "1h" });
  });

  it("reports unavailable providers without asserting the cause", () => {
    expect(
      getDominantSupplySignal(signals({ unavailableSheds1h: 3 })),
    ).toEqual({ kind: "unavailable", label: "No eligible provider", window: "1h" });
  });

  it("does not hide equal-strength hardware and capacity evidence", () => {
    expect(
      getDominantSupplySignal(
        signals({ capacitySheds1h: 2, hardwareMismatches1h: 2 }),
      ),
    ).toEqual({ kind: "mixed", label: "Mixed signals", window: "1h" });
  });

  it("reports no tracked rejects when no signal exists", () => {
    expect(getDominantSupplySignal(EMPTY_SIGNALS)).toEqual({
      kind: "none",
      label: "No tracked rejects",
      window: null,
    });
  });
});

describe("supply pressure summary", () => {
  it("totals served and rejected requests and counts recent signals", () => {
    const summary = summarizeSupplyPressure([
      model({
        model: "model-a",
        supplyRejects1h: 2,
        supplyRejects24h: 5,
        served24h: 15,
        capacitySheds1h: 2,
      }),
      model({
        model: "model-b",
        supplyRejects24h: 1,
        served24h: 4,
        hardwareMismatches1h: 1,
      }),
    ]);

    expect(summary).toEqual({
      supplyRejects1h: 2,
      supplyRejects24h: 6,
      served24h: 19,
      supplyRejectShare24h: 0.24,
      pressuredModels1h: 2,
    });
  });

  it("returns no reject share when there was no traffic", () => {
    expect(supplyRejectShare(0, 0)).toBeNull();
    expect(supplyRejectShare(2, 8)).toBe(0.2);
  });
});
