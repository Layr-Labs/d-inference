import { describe, it, expect } from "vitest";
import {
  providerCapabilityLabel,
  providerCapabilityLabels,
  providerRequirementBadge,
  providerRequirementTitle,
} from "./provider-capabilities";

describe("providerCapabilityLabel", () => {
  it("maps the known capabilities", () => {
    expect(providerCapabilityLabel("apple_m5")).toBe("Apple M5");
    expect(providerCapabilityLabel("mlx_nax")).toBe("NAX runtime");
  });

  it("falls back to the raw id for unknown values", () => {
    expect(providerCapabilityLabel("future_runtime")).toBe("future_runtime");
  });
});

describe("providerCapabilityLabels", () => {
  it("orders by wire id, de-duplicates, and drops blanks", () => {
    expect(providerCapabilityLabels(["mlx_nax", "apple_m5", "mlx_nax", "", "  "])).toEqual([
      "Apple M5",
      "NAX runtime",
    ]);
  });

  it("returns nothing for absent, null, empty, or non-array input", () => {
    expect(providerCapabilityLabels(undefined)).toEqual([]);
    expect(providerCapabilityLabels(null)).toEqual([]);
    expect(providerCapabilityLabels([])).toEqual([]);
    expect(providerCapabilityLabels("apple_m5" as unknown as string[])).toEqual([]);
  });
});

describe("providerRequirementBadge", () => {
  it("renders a single requirement", () => {
    expect(providerRequirementBadge(["apple_m5"])).toBe("Apple M5 only");
  });

  it("joins several requirements in wire-id order", () => {
    expect(providerRequirementBadge(["mlx_nax", "apple_m5"])).toBe("Apple M5 + NAX runtime only");
  });

  it("keeps unknown ids visible", () => {
    expect(providerRequirementBadge(["future_runtime"])).toBe("future_runtime only");
  });

  it("is null when there is nothing to show (including the API's empty array)", () => {
    expect(providerRequirementBadge([])).toBeNull();
    expect(providerRequirementBadge(undefined)).toBeNull();
    expect(providerRequirementBadge(null)).toBeNull();
  });
});

describe("providerRequirementTitle", () => {
  it("spells out the full requirement", () => {
    expect(providerRequirementTitle(["apple_m5", "mlx_nax"])).toBe(
      "Served only by providers with: Apple M5, NAX runtime",
    );
  });

  it("is null when there is nothing to show", () => {
    expect(providerRequirementTitle([])).toBeNull();
  });
});
