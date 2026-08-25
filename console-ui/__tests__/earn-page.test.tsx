import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { dedupeModelVariants, baseModelKey, buildCatalogModels } from "@/app/earn/calc";

const apiMocks = vi.hoisted(() => ({
  fetchModels: vi.fn(),
  fetchPricing: vi.fn(),
}));
const GPT_MODEL_ID = "gpt-oss-20b";
const GPT_MODEL_NAME = "GPT-OSS 20B";
const GEMMA_MODEL_ID = "gemma-4-26b";
const GEMMA_MODEL_NAME = "Gemma 4 26B";

vi.mock("@/components/TopBar", () => ({
  TopBar: ({ title }: { title?: string }) => (
    <div data-testid="topbar">{title}</div>
  ),
}));

vi.mock("@/hooks/useAuth", () => ({
  useAuth: () => ({
    ready: true,
    authenticated: true,
    login: vi.fn(),
  }),
}));

vi.mock("@/lib/google-analytics", () => ({
  trackEvent: vi.fn(),
}));

vi.mock("@/lib/api", () => ({
  fetchModels: apiMocks.fetchModels,
  fetchPricing: apiMocks.fetchPricing,
}));

vi.mock("@/app/providers/useProviderRequirements", () => ({
  useProviderRequirements: () => ({
    status: "ready",
    requirements: {
      policy: {
        version: 0,
        mode: "disabled",
        min_memory_gb: 0,
        min_memory_bandwidth_gbs: 0,
        min_fp16_millitflops: 0,
        catalog_version: "apple-silicon-v1",
      },
      accepting_new_providers: true,
      grandfather_existing: true,
      metric_definitions: {},
    },
  }),
}));

beforeEach(() => {
  apiMocks.fetchModels.mockReset();
  apiMocks.fetchPricing.mockReset();
  apiMocks.fetchModels.mockResolvedValue([
    {
      id: GPT_MODEL_ID,
      object: "model",
      display_name: GPT_MODEL_NAME,
      size_gb: 12.1,
      min_ram_gb: 24,
      architecture: "MoE",
    },
    {
      id: GEMMA_MODEL_ID,
      object: "model",
      display_name: GEMMA_MODEL_NAME,
      size_gb: 28,
      min_ram_gb: 36,
      architecture: "MoE",
    },
  ]);
  apiMocks.fetchPricing.mockResolvedValue({
    prices: [
      { model: GEMMA_MODEL_ID, input_price: 65_000, output_price: 200_000, input_usd: "$0.0650", output_usd: "$0.2000" },
    ],
  });
});

describe("model variant dedupe", () => {
  const variants = [
    { id: GPT_MODEL_ID, object: "model", display_name: GPT_MODEL_NAME, family: "gpt-oss" },
    { id: "gemma-4-26b-qat-4bit", object: "model", display_name: GEMMA_MODEL_NAME, family: "gemma" },
    { id: GEMMA_MODEL_ID, object: "model", display_name: GEMMA_MODEL_NAME, family: "gemma" },
    { id: "gemma-4-26b-8bit", object: "model", display_name: "Gemma 4 26B 8-bit (rollback)", family: "gemma" },
  ];

  it("strips quant / build suffixes to a base key", () => {
    expect(baseModelKey("gemma-4-26b-qat-4bit")).toBe(GEMMA_MODEL_ID);
    expect(baseModelKey("gemma-4-26b-8bit")).toBe(GEMMA_MODEL_ID);
    expect(baseModelKey(GEMMA_MODEL_ID)).toBe(GEMMA_MODEL_ID);
    expect(baseModelKey(GPT_MODEL_ID)).toBe(GPT_MODEL_ID);
  });

  it("collapses the catalog to one canonical entry per base model", () => {
    const out = dedupeModelVariants(variants);
    expect(out.map((m) => m.id).sort()).toEqual([GEMMA_MODEL_ID, GPT_MODEL_ID]);
  });

  it("buildCatalogModels yields exactly two clean models", () => {
    const built = buildCatalogModels(variants, null);
    expect(built.map((m) => m.name).sort()).toEqual([GPT_MODEL_NAME, GEMMA_MODEL_NAME]);
  });
});

describe("EarnPage", () => {
  it("shows the floor-only hero when no catalog model fits the selected hardware", async () => {
    const EarnPage = (await import("@/app/earn/page")).default;
    render(<EarnPage />);
    await screen.findAllByText(/Runs in your 48 GB/);

    fireEvent.change(screen.getByLabelText("Chip"), { target: { value: "M1" } });
    fireEvent.change(screen.getByLabelText("Unified memory"), { target: { value: "16" } });

    // Nothing fits in 16 GB (min RAM is 24/36 in the fixture) and the 16 GB
    // floor tier is $0 — the hero degrades honestly instead of disappearing.
    expect(
      await screen.findByText(/No catalog model fits in 16 GB/)
    ).toBeInTheDocument();
    expect(screen.getByText("Needs 24 GB+ of unified memory")).toBeInTheDocument();
    expect(screen.getByText("Needs 36 GB+ of unified memory")).toBeInTheDocument();
  });

  it("sends under-provisioned machines to durable availability registration", async () => {
    window.localStorage.clear();
    const EarnPage = (await import("@/app/earn/page")).default;
    render(<EarnPage />);
    await screen.findAllByText(/Runs in your 48 GB/);

    fireEvent.change(screen.getByLabelText("Chip"), { target: { value: "M1" } });
    fireEvent.change(screen.getByLabelText("Unified memory"), { target: { value: "16" } });

    const waitlistLink = await screen.findByRole("link", {
      name: /Register this Mac's hardware interest/,
    });
    expect(waitlistLink).toHaveAttribute(
      "href",
      "/provider-waitlist?chip=M1&memory_gb=16"
    );
    expect(window.localStorage.getItem("darkbloom.smallModelsInterest")).toBeNull();
  });

  it("always prices the best-earning model automatically (read-only list, no selection)", async () => {
    const EarnPage = (await import("@/app/earn/page")).default;
    render(<EarnPage />);

    // GPT-OSS 20B out-earns Gemma on the default M4 Max (fewer active params →
    // higher decode throughput) so it gets the badge; both fit in 48 GB.
    expect(await screen.findByText("Best earner")).toBeInTheDocument();
    expect(screen.getByText(/Runs in your 48 GB \(12 GB weights\)/)).toBeInTheDocument();
    expect(screen.getByText(/Runs in your 48 GB \(28 GB weights\)/)).toBeInTheDocument();

    // The list is read-only — no model checkboxes/buttons to mis-toggle.
    expect(screen.queryByRole("button", { name: /GPT-OSS 20B/ })).not.toBeInTheDocument();
  });

  it("presents earnings as a floor→estimate range with the base reward additive", async () => {
    const EarnPage = (await import("@/app/earn/page")).default;
    render(<EarnPage />);

    // Default hardware is M4 Max / 48GB → 48GB base-reward tier = $16/mo floor
    // (appears in both the hero chip and the formula breakdown).
    expect((await screen.findAllByText(/\$16\/mo/)).length).toBeGreaterThan(0);
    expect(screen.getByText("Base rewards (earnings floor)")).toBeInTheDocument();
    // Assumptions decomposition shows the floor added on top of usage.
    expect(screen.getByText("+ $16")).toBeInTheDocument();
  });

  it("bakes electricity in as a fixed assumption with no user input", async () => {
    const { DEFAULT_ELEC_COST_PER_KWH } = await import("@/app/earn/calc");
    const { useEarningsCalculator } = await import("@/app/earn/useEarningsCalculator");
    const { renderHook } = await import("@testing-library/react");
    const { result } = renderHook(() => useEarningsCalculator());

    expect(result.current.elecCostNum).toBe(DEFAULT_ELEC_COST_PER_KWH);

    const EarnPage = (await import("@/app/earn/page")).default;
    render(<EarnPage />);
    expect(screen.queryByLabelText(/Electricity cost/i)).not.toBeInTheDocument();
  });
});
