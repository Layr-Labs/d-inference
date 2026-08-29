import { describe, it, expect } from "vitest";
import { STRIPE_CONNECT_COUNTRIES } from "./stripe-countries";

const flagFor = (code: string) =>
  String.fromCodePoint(...[...code].map((c) => 0x1f1e6 + c.charCodeAt(0) - 65));

describe("STRIPE_CONNECT_COUNTRIES", () => {
  it("includes North Macedonia (issue #695)", () => {
    const mk = STRIPE_CONNECT_COUNTRIES.find((c) => c.code === "MK");
    expect(mk).toBeDefined();
    expect(mk!.name).toBe("North Macedonia");
    expect(mk!.flag).toBe(flagFor("MK"));
  });

  it("has unique ISO 3166-1 alpha-2 codes", () => {
    const codes = STRIPE_CONNECT_COUNTRIES.map((c) => c.code);
    expect(new Set(codes).size).toBe(codes.length);
  });

  it("uses well-formed uppercase two-letter codes", () => {
    for (const c of STRIPE_CONNECT_COUNTRIES) {
      expect(c.code).toMatch(/^[A-Z]{2}$/);
    }
  });

  it("stays sorted by code so additions land in a predictable place", () => {
    const codes = STRIPE_CONNECT_COUNTRIES.map((c) => c.code);
    expect(codes).toEqual([...codes].sort());
  });

  it("carries the flag emoji that matches each code", () => {
    for (const c of STRIPE_CONNECT_COUNTRIES) {
      expect(c.flag).toBe(flagFor(c.code));
    }
  });
});
