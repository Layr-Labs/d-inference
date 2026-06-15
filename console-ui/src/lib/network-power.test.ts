import { describe, expect, it } from "vitest";
import { estimateMachineWatts, activeNetworkPowerWatts } from "./network-power";

describe("estimateMachineWatts", () => {
  it("resolves table entries by family + tier", () => {
    expect(estimateMachineWatts("M1", "Max", 32)).toBe(115);
    expect(estimateMachineWatts("M4", "Pro", 20)).toBe(100);
    expect(estimateMachineWatts("M2", "Ultra", 60)).toBe(280);
    expect(estimateMachineWatts("M4", "Base", 10)).toBe(65);
    expect(estimateMachineWatts("M5", "Max", 40)).toBe(180);
  });

  it("is case-insensitive on tier and family", () => {
    expect(estimateMachineWatts("m1", "max", 32)).toBe(115);
    expect(estimateMachineWatts("M1", "MAX", 32)).toBe(115);
  });

  it("treats empty/unknown tier as Base", () => {
    expect(estimateMachineWatts("M4", "", 10)).toBe(65);
    expect(estimateMachineWatts("M4", undefined, 10)).toBe(65);
    expect(estimateMachineWatts("M4", "weird", 10)).toBe(65);
  });

  it("falls back to a gpu-core estimate for unknown families", () => {
    expect(estimateMachineWatts("Intel", "", 0)).toBe(30); // floor
    expect(estimateMachineWatts("", "", 10)).toBe(65); // 30 + 3.5*10
    expect(estimateMachineWatts("M9", "Max", 20)).toBe(100); // 30 + 3.5*20
  });
});

describe("activeNetworkPowerWatts", () => {
  it("prefers the coordinator-provided field when present", () => {
    expect(
      activeNetworkPowerWatts({ active_power_watts: 20855, providers: [] }),
    ).toBe(20855);
  });

  it("sums per-provider estimates when the field is absent", () => {
    const watts = activeNetworkPowerWatts({
      providers: [
        { chip_family: "M1", chip_tier: "Max", gpu_cores: 32 }, // 115
        { chip_family: "M4", chip_tier: "Pro", gpu_cores: 20 }, // 100
      ],
    });
    expect(watts).toBe(215);
  });

  it("returns 0 with no field and no providers", () => {
    expect(activeNetworkPowerWatts({})).toBe(0);
    expect(activeNetworkPowerWatts({ active_power_watts: 0, providers: [] })).toBe(0);
  });
});
