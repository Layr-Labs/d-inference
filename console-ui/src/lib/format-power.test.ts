import { describe, it, expect } from "vitest";
import { formatPower } from "./format-power";

describe("formatPower", () => {
  describe("examples from the spec", () => {
    it("formats sub-kW watts", () => {
      expect(formatPower(950)).toBe("950 W");
    });

    it("formats kW with one decimal", () => {
      expect(formatPower(20855)).toBe("20.9 kW");
    });

    it("formats large kW as an integer", () => {
      expect(formatPower(187000)).toBe("187 kW");
    });

    it("formats MW with one decimal", () => {
      expect(formatPower(1.4e6)).toBe("1.4 MW");
    });

    it("formats GW with one decimal", () => {
      expect(formatPower(2.1e9)).toBe("2.1 GW");
    });
  });

  describe("empty / invalid -> em dash", () => {
    it("returns dash for undefined", () => {
      expect(formatPower(undefined)).toBe("—");
    });

    it("returns dash for null", () => {
      expect(formatPower(null)).toBe("—");
    });

    it("returns dash for NaN", () => {
      expect(formatPower(NaN)).toBe("—");
    });

    it("returns dash for zero", () => {
      expect(formatPower(0)).toBe("—");
    });

    it("returns dash for negatives", () => {
      expect(formatPower(-500)).toBe("—");
    });

    it("returns dash for non-finite", () => {
      expect(formatPower(Infinity)).toBe("—");
    });
  });

  describe("rounding of plain watts", () => {
    it("rounds fractional watts", () => {
      expect(formatPower(949.6)).toBe("950 W");
    });

    it("keeps small whole watts", () => {
      expect(formatPower(1)).toBe("1 W");
    });
  });

  describe("W / kW boundary", () => {
    it("stays in W just below 1000", () => {
      expect(formatPower(999)).toBe("999 W");
    });

    it("crosses to kW at exactly 1000 (trailing .0 stripped)", () => {
      expect(formatPower(1000)).toBe("1 kW");
    });
  });

  describe("kW one-decimal vs integer boundary (100 kW)", () => {
    it("uses one decimal below 100 kW", () => {
      expect(formatPower(99_900)).toBe("99.9 kW");
    });

    it("uses an integer at exactly 100 kW", () => {
      expect(formatPower(100_000)).toBe("100 kW");
    });

    it("uses an integer for large kW values just under 1 MW", () => {
      expect(formatPower(999_999)).toBe("1000 kW");
    });
  });

  describe("kW / MW boundary", () => {
    it("crosses to MW at exactly 1e6 (trailing .0 stripped)", () => {
      expect(formatPower(1_000_000)).toBe("1 MW");
    });

    it("uses one decimal below 100 MW", () => {
      expect(formatPower(45_000_000)).toBe("45 MW");
    });

    it("uses one decimal for a fractional MW below 100", () => {
      expect(formatPower(45_500_000)).toBe("45.5 MW");
    });

    it("uses an integer at/above 100 MW", () => {
      expect(formatPower(150_000_000)).toBe("150 MW");
    });
  });

  describe("MW / GW boundary", () => {
    it("crosses to GW at exactly 1e9 (trailing .0 stripped)", () => {
      expect(formatPower(1_000_000_000)).toBe("1 GW");
    });

    it("uses one decimal below 100 GW", () => {
      expect(formatPower(2_500_000_000)).toBe("2.5 GW");
    });

    it("uses an integer at/above 100 GW", () => {
      expect(formatPower(120_000_000_000)).toBe("120 GW");
    });
  });
});
