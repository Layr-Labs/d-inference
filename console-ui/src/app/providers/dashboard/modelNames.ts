// Human-readable model names for the dashboard, from the coordinator's
// model_display_names on /v1/me/providers (raw build id -> catalog display
// name, e.g. "EigenLabs/Qwen3.8-27B-4bit-mtp" -> "Qwen 3.8 27B"; builds that
// share a name arrive already disambiguated, "Gemma 4 26B (4bit)"). Ids the
// catalog has no name for — off-catalog local models, older coordinators —
// fall back to the id without its org prefix, and render sites keep the raw id
// in the hover title.

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
