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
  it("keeps rendering when selected hardware has no eligible models", async () => {
    const EarnPage = (await import("@/app/earn/page")).default;
    render(<EarnPage />);

    fireEvent.click(screen.getByRole("button", { name: "MacBook Air" }));
    fireEvent.click(screen.getByRole("button", { name: "16 GB" }));

    expect(screen.getByText("Provider Earnings Calculator")).toBeInTheDocument();
    expect(await screen.findByText("No models fit in 16 GB RAM")).toBeInTheDocument();
    expect(screen.getByText("No compatible model for this hardware")).toBeInTheDocument();
  });

  it("allows adding another model when it fits beside the auto-selected model", async () => {
    const EarnPage = (await import("@/app/earn/page")).default;
    render(<EarnPage />);

    const gptButton = await screen.findByRole("button", { name: /GPT-OSS 20B/ });

    expect(screen.getByText("12 GB weights / 48 GB RAM")).toBeInTheDocument();
    expect(gptButton).not.toBeDisabled();
    fireEvent.click(gptButton);

    const gemmaButton = await screen.findByRole("button", { name: /Gemma 4 26B/ });
    expect(gemmaButton).not.toBeDisabled();
    fireEvent.click(gemmaButton);

    expect(
      screen.getByText("Selected models share active inference hours, so usage earnings are not double-counted.")
    ).toBeInTheDocument();
    expect(screen.getByText("40 GB weights / 48 GB RAM")).toBeInTheDocument();
  });

  it("adds the base-reward floor on top of usage earnings (additive, not max)", async () => {
    const EarnPage = (await import("@/app/earn/page")).default;
    render(<EarnPage />);

    // Default hardware is MacBook Pro / M4 Max / 48GB → 48GB base-reward tier = $16/mo,
    // at the default 24h online (100% uptime). The floor is shown on top of usage.
    expect(await screen.findByText("Base rewards (earnings floor)")).toBeInTheDocument();
    expect(await screen.findByText("+ $16.00")).toBeInTheDocument();
  });
});
