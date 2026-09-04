// Human-readable model names for the dashboard. The coordinator ships the
// catalog's id -> display-name map on /v1/me/providers (model_display_names,
// keyed by the raw build id providers advertise, e.g.
// "EigenLabs/Qwen3.8-27B-4bit-mtp" -> "Qwen 3.8 27B"). Built once per response
// into a Map so every chip, slot row, and label resolves in O(1); anything the
// catalog has no name for (off-catalog local models, older coordinators) falls
// back to the id minus its org prefix, and render sites keep the raw id in the
// hover title so it is always one hover away.

import type { MyProvidersResponse } from "../types";
import { shortModelName } from "./format";

export type ModelNames = ReadonlyMap<string, string>;

export const NO_MODEL_NAMES: ModelNames = new Map();

/** Index a fleet response's display names; an absent map yields an empty index. */
export function modelNamesFrom(resp: Pick<MyProvidersResponse, "model_display_names"> | null | undefined): ModelNames {
  return new Map(Object.entries(resp?.model_display_names ?? {}));
}

/** The catalog display name for a model id, else the id without its org prefix. */
export function modelDisplayName(id: string, names: ModelNames): string {
  return names.get(id) || shortModelName(id);
}
