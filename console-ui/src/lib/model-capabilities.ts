import type { Model } from "./api/types";

/** Native decisions use a separate API; model names do not determine capability. */
export function isDecisionModel(model: Model): boolean {
  return [...(model.capabilities ?? []), ...(model.supported_features ?? [])]
    .some((value) => value.trim().toLowerCase() === "system_one")
    || (model.output_modalities ?? []).some((value) => value.trim().toLowerCase() === "decision");
}

export function modelSupportsChat(model: Model): boolean {
  return !isDecisionModel(model);
}
