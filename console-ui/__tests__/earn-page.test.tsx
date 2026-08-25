import { fireEvent, render, screen } from "@testing-library/react";
import { createRequire } from "node:module";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Model } from "@/lib/api/types";
import {
  DEFAULT_DUTY_CYCLE_PERCENT,
  DECODE_BANDWIDTH_EFFICIENCY,
  HARDWARE_OPTIONS,
  buildCalculatorModels,
  calculateCapacityRevenue,
} from "@/app/earn/calc";
import {
  MIN_PROVIDER_MEMORY_GB,
  PROVIDER_HARDWARE_OPTIONS,
} from "@/app/earn/providerReadiness";

const MACBOOK_PRO = "MacBook Pro";
const MAC_STUDIO = "Mac Studio";
const M4_MAX = "M4 Max (16-core CPU)";
const BEST_ESTIMATE = "Best current estimate";
const MONTHLY_EARNING = "Estimated monthly earning";
const MODEL_OBJECT = "model";
const ZERO_PROMPT_PRICE = "0";
const QWEN_DISPLAY_NAME = "Qwen3.6 35B A3B";
const models: Model[] = [
  {
    id: "qwen3.6-35b-a3b-mxfp8",
    object: MODEL_OBJECT,
    display_name: QWEN_DISPLAY_NAME,
    min_ram_gb: 48,
    size_gb: 22,
  },
  {
    id: "gemma-4-26b-a4b-mxfp8",
    object: MODEL_OBJECT,
    display_name: "Gemma 4 26B A4B",
    min_ram_gb: 32,
    size_gb: 17,
    pricing: { prompt: ZERO_PROMPT_PRICE, completion: "0.00000022" },
  },
  {
    id: "gpt-oss-20b-mxfp4",
    object: MODEL_OBJECT,
    display_name: "GPT-OSS 20B",
    description: "3.6B active parameters",
    min_ram_gb: 24,
    size_gb: 12,
    pricing: { prompt: ZERO_PROMPT_PRICE, completion: "0.000000069" },
  },
];

const apiMocks = vi.hoisted(() => ({
  fetchModels: vi.fn(),
}));

vi.mock("@/components/TopBar", () => ({
  TopBar: ({ title }: { title?: string }) => <div data-testid="topbar">{title}</div>,
}));
vi.mock("@/hooks/useAuth", () => ({
  useAuth: () => ({ ready: true, authenticated: true, login: vi.fn() }),
}));
vi.mock("@/lib/google-analytics", () => ({ trackEvent: vi.fn() }));
vi.mock("@/lib/api", () => ({
  fetchModels: apiMocks.fetchModels,
}));

const requireFromTest = createRequire(import.meta.url);
const landingCore = requireFromTest("../../landing/earn-calculator-core.js") as {
  HARDWARE_OPTIONS: typeof HARDWARE_OPTIONS;
  MIN_PROVIDER_MEMORY_GB: number;
  PROVIDER_HARDWARE_OPTIONS: typeof PROVIDER_HARDWARE_OPTIONS;
  buildCalculatorModels: typeof buildCalculatorModels;
  calculateCapacityRevenue: typeof calculateCapacityRevenue;
};

beforeEach(() => {
  apiMocks.fetchModels.mockReset();
  apiMocks.fetchModels.mockResolvedValue(structuredClone(models));
});

function selectMac(macType = MACBOOK_PRO, chip = M4_MAX, ram = 48) {
  fireEvent.change(screen.getByLabelText("Mac model"), { target: { value: macType } });
  fireEvent.change(screen.getByLabelText("Chip family"), { target: { value: chip } });
  fireEvent.change(screen.getByLabelText("Unified memory"), {
    target: { value: String(ram) },
  });
}

describe("earnings projection", () => {
  it("builds model inputs from the existing catalog and hardcoded Qwen price", () => {
    const catalog = buildCalculatorModels(models);
    expect(catalog.map((model) => model.displayName)).toEqual([
      QWEN_DISPLAY_NAME,
      "Gemma 4 26B A4B",
      "GPT-OSS 20B",
    ]);
    expect(catalog[0]).toMatchObject({
      activeParameterCount: 3_000_000_000,
      bytesPerParameter: 22 / 35,
      outputPriceMicroUSDPerMillion: 700_000,
    });
  });

  it("uses 65% of bandwidth, active weights, output pricing, and duty cycle", () => {
    const hardware = HARDWARE_OPTIONS.find(
      (option) => option.macType === MACBOOK_PRO && option.chip === M4_MAX,
    )!;
    const model = buildCalculatorModels(models)[0];
    const estimate = calculateCapacityRevenue(model, hardware, 48, 50)!;
    expect(estimate.activeWeightGBPerToken).toBeCloseTo((3 * 22) / 35, 12);
    expect(estimate.decodeTokensPerSecond).toBeCloseTo(
      (hardware.bandwidthGBs * DECODE_BANDWIDTH_EFFICIENCY) / ((3 * 22) / 35),
      12,
    );
    expect(estimate.activeSecondsPerMonth).toBe(360 * 60 * 60);
    expect(estimate.outputPriceUSDPerMillion).toBe(0.7);
  });

  it("keeps the console and homepage data mapping and projection identical", () => {
    const hardware = HARDWARE_OPTIONS.find(
      (option) => option.macType === MACBOOK_PRO && option.chip === M4_MAX,
    )!;
    const consoleModels = buildCalculatorModels(models);
    const landingModels = landingCore.buildCalculatorModels(models);
    expect(landingModels).toEqual(consoleModels);
    expect(landingCore.calculateCapacityRevenue(landingModels[0], hardware, 48, 50)).toEqual(
      calculateCapacityRevenue(consoleModels[0], hardware, 48, 50),
    );
  });

  it("keeps only supported provider families and includes the new profiles", () => {
    expect(landingCore.HARDWARE_OPTIONS).toEqual(HARDWARE_OPTIONS);
    expect(landingCore.MIN_PROVIDER_MEMORY_GB).toBe(MIN_PROVIDER_MEMORY_GB);
    expect(landingCore.PROVIDER_HARDWARE_OPTIONS).toEqual(PROVIDER_HARDWARE_OPTIONS);
    expect(new Set(PROVIDER_HARDWARE_OPTIONS.map((option) => option.macType))).toEqual(
      new Set([MACBOOK_PRO, "Mac Mini", MAC_STUDIO, "Mac Pro"]),
    );
    expect(
      HARDWARE_OPTIONS.find((option) => option.macType === "Mac Mini" && option.chip === "M6"),
    ).toMatchObject({ bandwidthGBs: 170, ramOptions: [16, 24, 32] });
    expect(
      HARDWARE_OPTIONS.find(
        (option) => option.macType === MAC_STUDIO && option.chip === "M5 Ultra",
      ),
    ).toMatchObject({ bandwidthGBs: 1200, ramOptions: [96, 256, 512] });
  });
});

describe("EarnPage", () => {
  it("requires separate Mac, chip, and memory choices", async () => {
    const EarnPage = (await import("@/app/earn/page")).default;
    render(<EarnPage />);
    expect(screen.getByText("Your estimate will appear here")).toBeInTheDocument();
    expect(screen.getByLabelText("Chip family")).toBeDisabled();
    expect(screen.getByLabelText("Unified memory")).toBeDisabled();
    selectMac();
    expect(await screen.findByText(BEST_ESTIMATE)).toBeInTheDocument();
    expect(screen.getByLabelText("Duty cycle")).toHaveValue(
      String(DEFAULT_DUTY_CYCLE_PERCENT),
    );
  });

  it("offers only Mac families that can enter the provider flow", async () => {
    const EarnPage = (await import("@/app/earn/page")).default;
    render(<EarnPage />);
    expect(
      Array.from(
        (screen.getByLabelText("Mac model") as HTMLSelectElement).options,
        (option) => option.textContent,
      ),
    ).toEqual(["Select model", MACBOOK_PRO, "Mac Mini", MAC_STUDIO, "Mac Pro"]);
  });

  it("shows the capacity flow, prominent caveat, and setup CTA in order", async () => {
    const EarnPage = (await import("@/app/earn/page")).default;
    render(<EarnPage />);
    selectMac();
    expect(await screen.findByText(BEST_ESTIMATE)).toBeInTheDocument();
    expect(screen.getAllByText(QWEN_DISPLAY_NAME).length).toBeGreaterThan(0);
    expect(screen.getByText("3. Single-stream decode speed")).toBeInTheDocument();
    expect(screen.getByText("6. OpenRouter output pricing")).toBeInTheDocument();
    expect(screen.getByRole("note")).toHaveTextContent("Estimated earning, not guaranteed.");
    const setup = screen.getByText("Turn your Mac into a provider");
    const flow = screen.getByText("How this estimate is calculated");
    expect(setup.compareDocumentPosition(flow) & Node.DOCUMENT_POSITION_FOLLOWING).not.toBe(0);
  });

  it("updates the earning when duty cycle changes", async () => {
    const EarnPage = (await import("@/app/earn/page")).default;
    render(<EarnPage />);
    selectMac();
    await screen.findByText(BEST_ESTIMATE);
    const before = screen.getByText(MONTHLY_EARNING).parentElement?.textContent;
    fireEvent.change(screen.getByLabelText("Duty cycle"), { target: { value: "25" } });
    const after = screen.getByText(MONTHLY_EARNING).parentElement?.textContent;
    expect(after).not.toBe(before);
  });

  it("shows a terminal unavailable state when the catalog cannot load", async () => {
    apiMocks.fetchModels.mockRejectedValueOnce(new Error("catalog unavailable"));
    const EarnPage = (await import("@/app/earn/page")).default;
    render(<EarnPage />);
    selectMac();
    expect((await screen.findAllByText("Estimate unavailable")).length).toBeGreaterThan(0);
  });

  it("invites interest instead of enrollment below 48 GB", async () => {
    const EarnPage = (await import("@/app/earn/page")).default;
    render(<EarnPage />);
    selectMac(MACBOOK_PRO, "M4 Pro", 24);
    expect(
      await screen.findByText("We're starting with Macs that have 48 GB or more"),
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Register your interest" })).toBeInTheDocument();
    expect(screen.queryByText(MONTHLY_EARNING)).not.toBeInTheDocument();
  });
});
