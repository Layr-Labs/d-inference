import { describe, it, expect } from "vitest";
import { modelDisplayName, modelNamesFrom, NO_MODEL_NAMES } from "./modelNames";

const QWEN27 = "EigenLabs/Qwen3.8-27B-4bit-mtp";
const MOE = "qwen3.6-35b-a3b-vl-mtp-mxfp8";
const QWEN27_NAME = "Qwen 3.8 27B";

describe("modelNamesFrom", () => {
  it("indexes the response map", () => {
    const names = modelNamesFrom({ model_display_names: { [QWEN27]: QWEN27_NAME, [MOE]: "Qwen 3.6 35B A3B" } });
    expect(names.get(QWEN27)).toBe(QWEN27_NAME);
    expect(names.size).toBe(2);
  });

  it("is empty for an older coordinator that omits the key, or no response yet", () => {
    expect(modelNamesFrom({}).size).toBe(0);
    expect(modelNamesFrom(null).size).toBe(0);
    expect(modelNamesFrom(undefined).size).toBe(0);
  });
});

describe("modelDisplayName", () => {
  const names = modelNamesFrom({ model_display_names: { [QWEN27]: QWEN27_NAME } });

  it("returns the catalog display name for a known build id", () => {
    expect(modelDisplayName(QWEN27, names)).toBe(QWEN27_NAME);
  });

  it("falls back to the id without its org prefix for unknown ids", () => {
    expect(modelDisplayName("EigenLabs/local-experiment-4bit", names)).toBe("local-experiment-4bit");
    expect(modelDisplayName(MOE, NO_MODEL_NAMES)).toBe(MOE);
  });
});
