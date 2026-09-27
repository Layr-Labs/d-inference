import { act, renderHook, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { fetchModels, fetchPricing, type Model } from "@/lib/api";
import { useModelCatalog } from "./useModelCatalog";

vi.mock("@/lib/api", () => ({ fetchModels: vi.fn(), fetchPricing: vi.fn() }));

const models: Model[] = [{ id: "model-a", object: "model" }];
const pricing = { prices: [{ model: "model-a", input_price: 0, output_price: 200_000, input_usd: "0", output_usd: "0.20" }] };

describe("useModelCatalog", () => {
  beforeEach(() => vi.resetAllMocks());

  it("keeps the catalog usable when pricing fails, and retries to recover rates", async () => {
    vi.mocked(fetchModels).mockResolvedValue(models);
    vi.mocked(fetchPricing).mockRejectedValueOnce(new Error("unavailable")).mockResolvedValue(pricing);
    const { result } = renderHook(() => useModelCatalog());
    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.models).toEqual(models);
    expect(result.current.modelsError).toBe(false);
    expect(result.current.pricingError).toBe(true);
    expect(result.current.pricing).toBeNull();

    act(() => result.current.refresh());
    await waitFor(() => expect(result.current.pricing).toEqual(pricing));
    expect(result.current.pricingError).toBe(false);
  });

  it("distinguishes a successful empty catalog from a failed request", async () => {
    vi.mocked(fetchModels).mockResolvedValueOnce([]).mockRejectedValueOnce(new Error("unavailable"));
    vi.mocked(fetchPricing).mockResolvedValue(pricing);
    const { result } = renderHook(() => useModelCatalog());
    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.modelsError).toBe(false);
    act(() => result.current.refresh());
    await waitFor(() => expect(result.current.modelsError).toBe(true));
  });

  it("preserves known model details but removes stale rates after a failed refresh", async () => {
    vi.mocked(fetchModels).mockResolvedValueOnce(models).mockRejectedValueOnce(new Error("unavailable"));
    vi.mocked(fetchPricing).mockResolvedValueOnce(pricing).mockRejectedValueOnce(new Error("unavailable"));
    const { result } = renderHook(() => useModelCatalog());
    await waitFor(() => expect(result.current.loading).toBe(false));
    act(() => result.current.refresh());
    await waitFor(() => expect(result.current.modelsError).toBe(true));
    expect(result.current.models).toEqual(models);
    expect(result.current.pricing).toBeNull();
    expect(result.current.pricingError).toBe(true);
  });
});
