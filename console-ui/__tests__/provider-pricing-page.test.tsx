import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";

const authMocks = vi.hoisted(() => ({
  getAccessToken: vi.fn().mockResolvedValue("privy-token"),
  login: vi.fn(),
}));

vi.mock("@/hooks/useAuth", () => ({
  useAuth: () => ({
    ready: true,
    authenticated: true,
    login: authMocks.login,
    getAccessToken: authMocks.getAccessToken,
  }),
}));

describe("ProviderPricingPage", () => {
  let fetchMock: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchMock = vi.fn((input: RequestInfo | URL) => {
      const url = String(input);
      if (url.endsWith("/v1/pricing/me")) {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              account_id: "acct-1",
              max_discount_percent: 90,
              discounts: [
                {
                  scope: "account_global",
                  discount_bps: 2000,
                  discount_percent: 20,
                },
              ],
              prices: [
                {
                  model: "model-a",
                  base_input_price: 100000,
                  base_output_price: 200000,
                  input_price: 80000,
                  output_price: 160000,
                  discount_bps: 2000,
                  discount_percent: 20,
                  discount_scope: "account_global",
                  input_usd: "$0.0800",
                  output_usd: "$0.1600",
                },
              ],
            }),
            { status: 200 }
          )
        );
      }
      if (url.endsWith("/v1/me/providers")) {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              providers: [
                {
                  id: "provider-1",
                  serial_number: "SERIAL-1",
                  hardware: { chip_name: "M4 Max" },
                  models: [],
                  reputation: {},
                },
              ],
            }),
            { status: 200 }
          )
        );
      }
      return Promise.resolve(new Response("not found", { status: 404 }));
    });
    vi.stubGlobal("fetch", fetchMock);
    vi.stubGlobal("localStorage", {
      getItem: vi.fn().mockReturnValue(null),
      setItem: vi.fn(),
      removeItem: vi.fn(),
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("renders discount forms and effective price preview", async () => {
    const ProviderPricingPage = (await import("@/app/providers/pricing/page")).default;
    render(<ProviderPricingPage />);

    expect(await screen.findByText("Account Default")).toBeInTheDocument();
    expect(screen.getByText("Account Model")).toBeInTheDocument();
    expect(screen.getByText("Machine Model")).toBeInTheDocument();

    await waitFor(() => {
      expect(screen.getAllByText("model-a").length).toBeGreaterThan(0);
    });
    expect(screen.getByText("$0.0800")).toBeInTheDocument();
    expect(screen.getByText("$0.1600")).toBeInTheDocument();
    expect(screen.getAllByText("20.00%").length).toBeGreaterThan(0);
  });
});
