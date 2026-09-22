import { describe, expect, it } from "vitest";
import { isDecisionModel, modelSupportsChat } from "./model-capabilities";
import { useStore } from "./store";
import type { Model } from "./api/types";

describe("decision model chat eligibility", () => {
  it.each([
    { capabilities: [" SYSTEM_ONE "] },
    { supported_features: ["system_one"] },
    { output_modalities: [" DECISION "] },
  ])("uses advertised metadata regardless of model name: %j", (capability) => {
    expect(isDecisionModel({ id: "arbitrary", object: "model", ...capability })).toBe(true);
    expect(modelSupportsChat({ id: "laya", object: "model" })).toBe(true);
  });

  it("preserves the full stored catalog while replacing an ineligible selection", () => {
    const models: Model[] = [
      { id: "native", object: "model", capabilities: ["system_one"] },
      { id: "chat", object: "model", output_modalities: ["text"] },
    ];
    useStore.setState({ selectedModel: "native" });
    useStore.getState().setModels(models);
    expect(useStore.getState().models).toEqual(models);
    expect(useStore.getState().selectedModel).toBe("chat");
    useStore.getState().setModels([models[0]]);
    expect(useStore.getState().selectedModel).toBe("");
    expect(useStore.getState().models).toEqual([models[0]]);
  });
});
