import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { dedupeModelVariants, baseModelKey, buildCatalogModels } from "@/app/earn/calc";

const apiMocks = vi.hoisted(() => ({
  fetchModels: vi.fn(),
  fetchPricing: vi.fn(),
}));

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

beforeEach(() => {
  apiMocks.fetchModels.mockReset();
  apiMocks.fetchPricing.mockReset();
  apiMocks.fetchModels.mockResolvedValue([
    {
      id: "gpt-oss-20b",
      object: "model",
      display_name: "GPT-OSS 20B",
      size_gb: 12.1,
      min_ram_gb: 24,
      architecture: "MoE",
    },
    {
      id: "gemma-4-26b",
      object: "model",
      display_name: "Gemma 4 26B",
      size_gb: 28,
      min_ram_gb: 36,
      architecture: "MoE",
    },
  ]);
  apiMocks.fetchPricing.mockResolvedValue({
    prices: [
      { model: "gemma-4-26b", input_price: 65_000, output_price: 200_000, input_usd: "$0.0650", output_usd: "$0.2000" },
    ],
  });
});

describe("model variant dedupe", () => {
  const variants = [
    { id: "gpt-oss-20b", object: "model", display_name: "GPT-OSS 20B", family: "gpt-oss" },
    { id: "gemma-4-26b-qat-4bit", object: "model", display_name: "Gemma 4 26B", family: "gemma" },
    { id: "gemma-4-26b", object: "model", display_name: "Gemma 4 26B", family: "gemma" },
    { id: "gemma-4-26b-8bit", object: "model", display_name: "Gemma 4 26B 8-bit (rollback)", family: "gemma" },
  ];

  it("strips quant / build suffixes to a base key", () => {
    expect(baseModelKey("gemma-4-26b-qat-4bit")).toBe("gemma-4-26b");
    expect(baseModelKey("gemma-4-26b-8bit")).toBe("gemma-4-26b");
    expect(baseModelKey("gemma-4-26b")).toBe("gemma-4-26b");
    expect(baseModelKey("gpt-oss-20b")).toBe("gpt-oss-20b");
  });

  it("collapses the catalog to one canonical entry per base model", () => {
    const out = dedupeModelVariants(variants);
    expect(out.map((m) => m.id).sort()).toEqual(["gemma-4-26b", "gpt-oss-20b"]);
  });

  it("buildCatalogModels yields exactly two clean models", () => {
    const built = buildCatalogModels(variants, null);
    expect(built.map((m) => m.name).sort()).toEqual(["GPT-OSS 20B", "Gemma 4 26B"]);
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

  it("lets under-provisioned machines register interest in smaller models", async () => {
    window.localStorage.clear();
    const EarnPage = (await import("@/app/earn/page")).default;
    render(<EarnPage />);
    await screen.findAllByText(/Runs in your 48 GB/);

    fireEvent.change(screen.getByLabelText("Chip"), { target: { value: "M1" } });
    fireEvent.change(screen.getByLabelText("Unified memory"), { target: { value: "16" } });

    const notifyButton = await screen.findByRole("button", {
      name: /Notify me when smaller models launch/,
    });
    fireEvent.click(notifyButton);

    expect(
      await screen.findByText(/You're on the list — we'll notify you when smaller models go live/)
    ).toBeInTheDocument();
    expect(window.localStorage.getItem("darkbloom.smallModelsInterest")).toContain('"chip":"M1"');
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
