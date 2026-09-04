// @vitest-environment jsdom
import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { ModelsStrip } from "./ModelsStrip";
import { BackendSlotsPanel } from "./BackendSlotsPanel";
import { makeProvider } from "./testFixtures";
import { modelNamesFrom } from "./modelNames";
import type { MyBackendCapacity } from "../types";

const QWEN27 = "EigenLabs/Qwen3.8-27B-4bit-mtp";
const MOE = "qwen3.6-35b-a3b-vl-mtp-mxfp8";
const LOCAL = "EigenLabs/local-experiment-4bit";
const QWEN27_NAME = "Qwen 3.8 27B";
const MOE_NAME = "Qwen 3.6 35B A3B";

const names = modelNamesFrom({ model_display_names: { [QWEN27]: QWEN27_NAME, [MOE]: MOE_NAME } });

const cap: MyBackendCapacity = {
  slots: [
    { model: MOE, state: "idle", num_running: 0, num_waiting: 0, active_tokens: 0, max_tokens_potential: 8192, observed_decode_tps: 88.4 },
    { model: QWEN27, state: "running", num_running: 1, num_waiting: 0, active_tokens: 512, max_tokens_potential: 8192 },
  ],
  gpu_memory_active_gb: 38.1,
  gpu_memory_peak_gb: 40,
  gpu_memory_cache_gb: 1.6,
  total_memory_gb: 64,
};

const provider = makeProvider({
  status: "serving",
  online: true,
  current_model: QWEN27,
  warm_models: [QWEN27, MOE],
  backend_capacity: cap,
  models: [{ id: QWEN27 }, { id: MOE }, { id: LOCAL }],
});

describe("ModelsStrip display names", () => {
  it("labels loaded and catalog chips with catalog display names, raw id on hover", () => {
    render(<ModelsStrip provider={provider} names={names} />);
    // Loaded + catalog chips both carry the display name.
    expect(screen.getAllByText(QWEN27_NAME)).toHaveLength(2);
    expect(screen.getAllByText(MOE_NAME)).toHaveLength(2);
    expect(screen.getAllByTitle(QWEN27)).toHaveLength(2);
    expect(screen.queryByText("Qwen3.8-27B-4bit-mtp")).toBeNull();
  });

  it("falls back to the short raw id for a model the catalog has no name for", () => {
    render(<ModelsStrip provider={provider} names={names} />);
    expect(screen.getByText("local-experiment-4bit")).toBeInTheDocument();
    expect(screen.getByTitle(LOCAL)).toBeInTheDocument();
  });

  it("renders short raw ids when no names are supplied (older coordinator)", () => {
    render(<ModelsStrip provider={provider} />);
    expect(screen.getAllByText("Qwen3.8-27B-4bit-mtp")).toHaveLength(2);
    expect(screen.queryByText(QWEN27_NAME)).toBeNull();
  });
});

describe("BackendSlotsPanel display names", () => {
  it("labels slot rows with display names and keeps the raw id on hover", () => {
    render(<BackendSlotsPanel cap={cap} names={names} />);
    expect(screen.getByText(MOE_NAME)).toBeInTheDocument();
    expect(screen.getByText(QWEN27_NAME)).toBeInTheDocument();
    expect(screen.getByTitle(MOE)).toBeInTheDocument();
    expect(screen.getByText("0 run · 0 wait · 88.4 tok/s")).toBeInTheDocument();
  });
});
