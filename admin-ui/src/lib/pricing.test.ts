import { describe, expect, it } from "vitest";
import { DEFAULT_INPUT_PRICE_MICRO, derivedCacheReadMicro } from "./pricing";

describe("derivedCacheReadMicro", () => {
  it("halves the row's input price, flooring to whole micro-USD like the coordinator", () => {
    expect(derivedCacheReadMicro("300000")).toBe(150_000);
    expect(derivedCacheReadMicro("50001")).toBe(25_000);
    expect(derivedCacheReadMicro("1")).toBe(0);
  });

  it("falls back to the default input price when the model has no price row", () => {
    expect(derivedCacheReadMicro(null)).toBe(DEFAULT_INPUT_PRICE_MICRO / 2);
    expect(derivedCacheReadMicro("")).toBe(DEFAULT_INPUT_PRICE_MICRO / 2);
    expect(derivedCacheReadMicro("not-a-number")).toBe(DEFAULT_INPUT_PRICE_MICRO / 2);
  });
});
