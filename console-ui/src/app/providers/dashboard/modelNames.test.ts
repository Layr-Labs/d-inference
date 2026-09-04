import { describe, it, expect } from "vitest";
import { modelDisplayName, modelNamesFrom, NO_MODEL_NAMES } from "./modelNames";
import { makeModelNames, MOE_ID, QWEN27_ID, QWEN27_NAME } from "./testFixtures";

describe("modelNamesFrom", () => {
  it("indexes the response map", () => {
    const names = makeModelNames();
    expect(names.get(QWEN27_ID)).toBe(QWEN27_NAME);
    expect(names.size).toBe(2);
  });

  it("is empty for an older coordinator that omits the key, or no response yet", () => {
    expect(modelNamesFrom({}).size).toBe(0);
    expect(modelNamesFrom(null).size).toBe(0);
    expect(modelNamesFrom(undefined).size).toBe(0);
  });
});

describe("modelDisplayName", () => {
  const names = makeModelNames();

  it("returns the catalog display name for a known build id", () => {
    expect(modelDisplayName(QWEN27_ID, names)).toBe(QWEN27_NAME);
  });

  it("falls back to the id without its org prefix for unknown ids", () => {
    expect(modelDisplayName("EigenLabs/local-experiment-4bit", names)).toBe("local-experiment-4bit");
    expect(modelDisplayName(MOE_ID, NO_MODEL_NAMES)).toBe(MOE_ID);
  });
});
