import { describe, it, expect } from "vitest";
import {
  asRecord,
  asString,
  asNumber,
  asBoolean,
  asStringArray,
  compactObject,
} from "@/lib/json";

describe("lib/json coercers", () => {
  it("asRecord returns plain objects, {} otherwise", () => {
    expect(asRecord({ a: 1 })).toEqual({ a: 1 });
    expect(asRecord([1, 2])).toEqual({});
    expect(asRecord(null)).toEqual({});
    expect(asRecord("x")).toEqual({});
    expect(asRecord(undefined)).toEqual({});
  });

  it("asString trims and rejects empties/non-strings", () => {
    expect(asString("  hi  ")).toBe("hi");
    expect(asString("")).toBeUndefined();
    expect(asString("   ")).toBeUndefined();
    expect(asString(5)).toBeUndefined();
  });

  it("asNumber accepts only finite numbers", () => {
    expect(asNumber(3.5)).toBe(3.5);
    expect(asNumber(0)).toBe(0);
    expect(asNumber(NaN)).toBeUndefined();
    expect(asNumber(Infinity)).toBeUndefined();
    expect(asNumber("3")).toBeUndefined();
  });

  it("asBoolean distinguishes absent from false", () => {
    expect(asBoolean(true)).toBe(true);
    expect(asBoolean(false)).toBe(false);
    expect(asBoolean(0)).toBeUndefined();
    expect(asBoolean(undefined)).toBeUndefined();
  });

  it("asStringArray keeps non-empty strings, undefined when none", () => {
    expect(asStringArray(["a", "", "b", 3])).toEqual(["a", "b"]);
    expect(asStringArray([])).toBeUndefined();
    expect(asStringArray(["", ""])).toBeUndefined();
    expect(asStringArray("a")).toBeUndefined();
  });

  it("compactObject drops only undefined keys", () => {
    expect(compactObject({ a: 1, b: undefined, c: null, d: 0, e: "" })).toEqual({
      a: 1,
      c: null,
      d: 0,
      e: "",
    });
  });
});
