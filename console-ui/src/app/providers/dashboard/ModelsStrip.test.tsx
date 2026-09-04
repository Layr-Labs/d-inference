// @vitest-environment jsdom
import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { ModelsStrip } from "./ModelsStrip";
import { BackendSlotsPanel } from "./BackendSlotsPanel";
import { makeModelNames, makeProvider, makeSlot, MOE_ID, MOE_NAME, QWEN27_ID, QWEN27_NAME } from "./testFixtures";
import { NO_MODEL_NAMES } from "./modelNames";
import type { MyBackendCapacity } from "../types";

const LOCAL = "EigenLabs/local-experiment-4bit";
const names = makeModelNames();

const cap: MyBackendCapacity = {
  slots: [
    makeSlot(MOE_ID, { observed_decode_tps: 88.4 }),
    makeSlot(QWEN27_ID, { state: "running", num_running: 1, active_tokens: 512 }),
  ],
  gpu_memory_active_gb: 38.1,
  gpu_memory_peak_gb: 40,
  gpu_memory_cache_gb: 1.6,
  total_memory_gb: 64,
};

const provider = makeProvider({
  status: "serving",
  online: true,
  current_model: QWEN27_ID,
  warm_models: [QWEN27_ID, MOE_ID],
  backend_capacity: cap,
  models: [{ id: QWEN27_ID }, { id: MOE_ID }, { id: LOCAL }],
});

describe("ModelsStrip display names", () => {
  it("labels loaded and catalog chips with catalog display names, raw id on hover", () => {
    render(<ModelsStrip provider={provider} names={names} />);
    // Loaded + catalog chips both carry the display name.
    expect(screen.getAllByText(QWEN27_NAME)).toHaveLength(2);
    expect(screen.getAllByText(MOE_NAME)).toHaveLength(2);
    expect(screen.getAllByTitle(QWEN27_ID)).toHaveLength(2);
    expect(screen.queryByText("Qwen3.8-27B-4bit-mtp")).toBeNull();
  });

  it("falls back to the short raw id for a model the catalog has no name for", () => {
    render(<ModelsStrip provider={provider} names={names} />);
    expect(screen.getByText("local-experiment-4bit")).toBeInTheDocument();
    expect(screen.getByTitle(LOCAL)).toBeInTheDocument();
  });

  it("renders short raw ids when the coordinator sent no names", () => {
    render(<ModelsStrip provider={provider} names={NO_MODEL_NAMES} />);
    expect(screen.getAllByText("Qwen3.8-27B-4bit-mtp")).toHaveLength(2);
    expect(screen.queryByText(QWEN27_NAME)).toBeNull();
  });
});

describe("BackendSlotsPanel display names", () => {
  it("labels slot rows with display names and keeps the raw id on hover", () => {
    render(<BackendSlotsPanel cap={cap} names={names} />);
    expect(screen.getByText(MOE_NAME)).toBeInTheDocument();
    expect(screen.getByText(QWEN27_NAME)).toBeInTheDocument();
    expect(screen.getByTitle(MOE_ID)).toBeInTheDocument();
    expect(screen.getByText("0 run · 0 wait · 88.4 tok/s")).toBeInTheDocument();
  });
});
