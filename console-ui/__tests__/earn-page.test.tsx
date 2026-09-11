import { fireEvent, render, screen } from "@testing-library/react";
import { createRequire } from "node:module";
import { describe, expect, it, vi } from "vitest";
import {
  CALCULATOR_MODELS,
  DEFAULT_DUTY_CYCLE_PERCENT,
  HARDWARE_OPTIONS,
  PREFILL_TO_DECODE_RATIO,
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
const QWEN_DISPLAY_NAME = "Qwen 3.6 35B A3B";
const QWEN_MODEL_ID = "qwen3.6-35b-a3b-vl-mtp-mxfp8";

vi.mock("@/components/TopBar", () => ({
  TopBar: ({ title }: { title?: string }) => <div data-testid="topbar">{title}</div>,
}));
vi.mock("@/hooks/useAuth", () => ({
  useAuth: () => ({ ready: true, authenticated: true, login: vi.fn() }),
}));
vi.mock("@/lib/google-analytics", () => ({ trackEvent: vi.fn() }));

const requireFromTest = createRequire(import.meta.url);
const landingCore = requireFromTest("../../landing/earn-calculator-core.js") as {
  HARDWARE_OPTIONS: typeof HARDWARE_OPTIONS;
  MIN_PROVIDER_MEMORY_GB: number;
  PROVIDER_HARDWARE_OPTIONS: typeof PROVIDER_HARDWARE_OPTIONS;
  CALCULATOR_MODELS: typeof CALCULATOR_MODELS;
  calculateCapacityRevenue: typeof calculateCapacityRevenue;
};

function selectMac(macType = MACBOOK_PRO, chip = M4_MAX, ram = 48) {
  fireEvent.change(screen.getByLabelText("Mac model"), { target: { value: macType } });
  fireEvent.change(screen.getByLabelText("Chip family"), { target: { value: chip } });
  fireEvent.change(screen.getByLabelText("Unified memory"), {
    target: { value: String(ram) },
  });
}

function qwenModel() {
  return CALCULATOR_MODELS.find((model) => model.id === QWEN_MODEL_ID)!;
}

describe("earnings projection", () => {
  it("pins current serving models, active weights, and prices", () => {
    expect(CALCULATOR_MODELS.map((model) => model.id)).toEqual([
      "Qwen3.5-9B",
      "gpt-oss-20b",
      "gemma-4-26b-qat-4bit",
      "EigenLabs/Qwen3.8-27B-4bit-mtp",
      "qwen3-vl-30b-a3b-instruct",
      "nvidia-nemotron-3.5-lightning",
      "qwen3.5-35b-a3b",
      QWEN_MODEL_ID,
    ]);
    expect(CALCULATOR_MODELS.map((model) => model.activeParameterCount)).toEqual([
      9_000_000_000,
      3_600_000_000,
      4_000_000_000,
      27_000_000_000,
      3_000_000_000,
      3_000_000_000,
      3_000_000_000,
      3_000_000_000,
    ]);
    expect(CALCULATOR_MODELS.map((model) => model.outputPriceMicroUSDPerMillion)).toEqual([
      130_000,
      100_000,
      220_000,
      2_000_000,
      400_000,
      180_000,
      750_000,
      700_000,
    ]);
    expect(CALCULATOR_MODELS.map((model) => model.inputPriceMicroUSDPerMillion)).toEqual([
      80_000,
      20_000,
      42_000,
      150_000,
      90_000,
      65_000,
      80_000,
      50_000,
    ]);
  });

  it("defaults duty cycle to 25%", () => {
    expect(DEFAULT_DUTY_CYCLE_PERCENT).toBe(25);
  });

  it("uses prefill, decode, the live token mix, and KV-limited concurrency", () => {
    const hardware = HARDWARE_OPTIONS.find(
      (option) => option.macType === MACBOOK_PRO && option.chip === M4_MAX,
    )!;
    const model = qwenModel();
    const estimate = calculateCapacityRevenue(model, hardware, 48, 25)!;
    expect(estimate.activeWeightGBPerToken).toBeCloseTo(21.309 * (3 / 35), 12);
    expect(estimate.decodeTokensPerSecond).toBeCloseTo(
      (hardware.bandwidthGBs * model.decodeBandwidthEfficiency) / (21.309 * (3 / 35)),
      12,
    );
    expect(estimate.prefillTokensPerSecond).toBeCloseTo(
      estimate.decodeTokensPerSecond * PREFILL_TO_DECODE_RATIO,
      12,
    );
    expect(estimate.activeSecondsPerMonth).toBe(180 * 60 * 60);
    expect(estimate.typicalPromptTokens).toBe(3200);
    expect(estimate.typicalCompletionTokens).toBe(400);
    expect(estimate.inputPriceUSDPerMillion).toBe(0.05);
    expect(estimate.outputPriceUSDPerMillion).toBe(0.7);
    expect(estimate.inputRevenueUSD).toBeGreaterThan(0);
    expect(estimate.maxConcurrency).toBe(4);
    expect(estimate.effectiveConcurrency).toBeCloseTo(1.75, 12);
  });

  it("keeps the console and homepage data mapping and projection identical", () => {
    const hardware = HARDWARE_OPTIONS.find(
      (option) => option.macType === MACBOOK_PRO && option.chip === M4_MAX,
    )!;
    expect(landingCore.CALCULATOR_MODELS).toEqual(CALCULATOR_MODELS);
    expect(
      landingCore.calculateCapacityRevenue(
        landingCore.CALCULATOR_MODELS.find((model) => model.id === QWEN_MODEL_ID)!,
        hardware,
        48,
        50,
      ),
    ).toEqual(
      calculateCapacityRevenue(qwenModel(), hardware, 48, 50),
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
    expect(screen.getByText("3. Prefill and decode speed")).toBeInTheDocument();
    expect(screen.getByText("4. Concurrency this Mac can hold")).toBeInTheDocument();
    expect(screen.getByText("7. Input and output pricing")).toBeInTheDocument();
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
    fireEvent.change(screen.getByLabelText("Duty cycle"), { target: { value: "50" } });
    const after = screen.getByText(MONTHLY_EARNING).parentElement?.textContent;
    expect(after).not.toBe(before);
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
