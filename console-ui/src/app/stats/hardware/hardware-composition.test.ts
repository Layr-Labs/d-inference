import { describe, expect, it } from "vitest";
import { buildHardwareComposition, hardwareShare } from "./hardware-composition";
import { hardwareProvider, hardwareStats } from "./hardware-test-fixtures";


describe("hardware composition", () => {
  it("keeps provider and memory denominators separate while merging tiers into chip generations", () => {
    const data = buildHardwareComposition(hardwareStats([
      hardwareProvider(), hardwareProvider({ chip: "Apple M4 Max", chip_family: "m4", memory_gb: 128 }),
      hardwareProvider({ chip_family: "M3", memory_gb: 96 }),
    ]));
    expect(data.providers).toBe(3);
    expect(data.memoryGB).toBe(288);
    expect(data.families).toHaveLength(2);
    expect(data.families[0]).toMatchObject({ key: "m4", label: "M4", providers: 2, memoryGB: 192 });
    expect(data.chartFamilies.reduce((sum, family) => sum + family.providers, 0)).toBe(3);
  });

  it("preserves missing chip metadata and only infers a generation from an explicit chip name", () => {
    const data = buildHardwareComposition(hardwareStats([
      hardwareProvider({ chip_family: "", chip: "Apple M5 Pro" }),
      hardwareProvider({ chip_family: "", chip: "" }),
      hardwareProvider({ chip_family: "unknown", chip: "" }),
    ]));
    expect(data.families.find((family) => family.key === "m5")?.providers).toBe(1);
    expect(data.chartFamilies.find((family) => family.key === "unknown")).toMatchObject({ label: "Unreported", providers: 2, memoryGB: 128 });
    expect(data.providers).toBe(3);
  });

  it("excludes missing or invalid memory sizes without dropping providers", () => {
    const data = buildHardwareComposition(hardwareStats([
      hardwareProvider(), hardwareProvider({ memory_gb: 0 }), hardwareProvider({ memory_gb: Number.NaN }),
      hardwareProvider({ memory_gb: -32 }), hardwareProvider({ memory_gb: Number.POSITIVE_INFINITY }),
    ]));
    expect(data.providers).toBe(5);
    expect(data.memoryGB).toBe(64);
    expect(data.memoryUnreportedProviders).toBe(4);
    expect(data.families[0].memoryReportedProviders).toBe(1);
  });

  it("bounds displayed groups while preserving every provider, memory total, and unknown group", () => {
    const providers = Array.from({ length: 12 }, (_, index) => hardwareProvider({ chip_family: `M${index + 1}`, memory_gb: 16 }));
    providers.push(hardwareProvider({ chip_family: "", chip: "", memory_gb: 32 }));
    const data = buildHardwareComposition(hardwareStats(providers));
    expect(data.chartFamilies).toHaveLength(7);
    expect(data.chartFamilies.reduce((sum, family) => sum + family.providers, 0)).toBe(13);
    expect(data.chartFamilies.reduce((sum, family) => sum + family.memoryGB, 0)).toBe(224);
    expect(data.chartFamilies.find((family) => family.key === "other")?.providers).toBe(7);
    expect(data.chartFamilies.find((family) => family.key === "unknown")?.providers).toBe(1);
  });

  it("distinguishes confirmed hardware identity, other states, and unpublished verification", () => {
    const data = buildHardwareComposition(hardwareStats([
      hardwareProvider({ routable: false }), hardwareProvider({ attested: false }),
      hardwareProvider({ attested: undefined }), hardwareProvider({ trust_level: "basic" }),
      hardwareProvider({ trust_level: "" }),
    ]));
    expect(data.hardwareAttestedProviders).toBe(1);
    expect(data.otherAttestationProviders).toBe(2);
    expect(data.attestationUnreportedProviders).toBe(2);
    expect(data.hardwareAttestedProviders + data.otherAttestationProviders + data.attestationUnreportedProviders).toBe(data.providers);
  });

  it("does not invent shares for an empty directory", () => {
    const data = buildHardwareComposition(hardwareStats([]));
    expect(data.providers).toBe(0);
    expect(data.memoryGB).toBe(0);
    expect(data.chartFamilies).toEqual([]);
    expect(hardwareShare(0, 0)).toBe("—");
  });
});
