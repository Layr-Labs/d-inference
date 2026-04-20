import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  fetchBalance,
  fetchUsage,
  deposit,
  withdraw,
  redeemInviteCode,
  fetchModels,
  fetchPricing,
  healthCheck,
} from "@/lib/api";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Build a minimal Response mock for JSON responses. */
function jsonResponse(body: unknown, status = 200): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(body),
    text: () => Promise.resolve(JSON.stringify(body)),
    headers: new Headers(),
  } as unknown as Response;
}

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);

  // Provide a minimal localStorage so getConfig() works
  const store: Record<string, string> = {};
  vi.stubGlobal("localStorage", {
    getItem: (k: string) => store[k] ?? null,
    setItem: (k: string, v: string) => {
      store[k] = v;
    },
    removeItem: (k: string) => {
      delete store[k];
    },
  });
});

afterEach(() => {
  vi.restoreAllMocks();
});

// ---------------------------------------------------------------------------
// fetchBalance
// ---------------------------------------------------------------------------

describe("fetchBalance", () => {
  it("calls /api/payments/balance with correct headers", async () => {
    const payload = { balance_micro_usd: 5_000_000, balance_usd: 5.0 };
    fetchMock.mockResolvedValueOnce(jsonResponse(payload));

    const result = await fetchBalance();

    expect(fetchMock).toHaveBeenCalledOnce();
    const [url, opts] = fetchMock.mock.calls[0];
    expect(url).toBe("/api/payments/balance");
    expect(opts.headers["Content-Type"]).toBe("application/json");
    expect(opts.headers["x-coordinator-url"]).toBeDefined();
    expect(result).toEqual(payload);
  });

  it("throws on non-ok response", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({}, 500));
    await expect(fetchBalance()).rejects.toThrow("Failed to fetch balance: 500");
  });
});

// ---------------------------------------------------------------------------
// fetchUsage
// ---------------------------------------------------------------------------

describe("fetchUsage", () => {
  it("calls /api/payments/usage and unwraps { usage: [...] }", async () => {
    const entries = [
      {
        request_id: "r1",
        model: "test-model",
        prompt_tokens: 10,
        completion_tokens: 20,
        cost_micro_usd: 100,
        timestamp: "2025-01-01T00:00:00Z",
      },
    ];
    fetchMock.mockResolvedValueOnce(jsonResponse({ usage: entries }));

    const result = await fetchUsage();

    expect(fetchMock).toHaveBeenCalledOnce();
    const [url] = fetchMock.mock.calls[0];
    expect(url).toBe("/api/payments/usage");
    expect(result).toEqual(entries);
  });

  it("returns raw array if response has no .usage wrapper", async () => {
    const entries = [
      {
        request_id: "r2",
        model: "m",
        prompt_tokens: 1,
        completion_tokens: 2,
        cost_micro_usd: 50,
        timestamp: "2025-06-01T00:00:00Z",
      },
    ];
    fetchMock.mockResolvedValueOnce(jsonResponse(entries));

    const result = await fetchUsage();
    expect(result).toEqual(entries);
  });

  it("throws on non-ok response", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({}, 403));
    await expect(fetchUsage()).rejects.toThrow("Failed to fetch usage: 403");
  });
});

// ---------------------------------------------------------------------------
// deposit
// ---------------------------------------------------------------------------

describe("deposit", () => {
  it("sends POST to /api/payments/deposit with amount_usd in body", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ ok: true }));

    await deposit(25);

    expect(fetchMock).toHaveBeenCalledOnce();
    const [url, opts] = fetchMock.mock.calls[0];
    expect(url).toBe("/api/payments/deposit");
    expect(opts.method).toBe("POST");
    expect(JSON.parse(opts.body)).toEqual({ amount_usd: 25 });
  });

  it("throws on failure", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({}, 400));
    await expect(deposit(0)).rejects.toThrow("Deposit failed (400)");
  });
});

// ---------------------------------------------------------------------------
// withdraw
// ---------------------------------------------------------------------------

describe("withdraw", () => {
  it("sends POST to /api/payments/withdraw with amount and wallet address", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ ok: true }));

    await withdraw(10, "0xabc123");

    expect(fetchMock).toHaveBeenCalledOnce();
    const [url, opts] = fetchMock.mock.calls[0];
    expect(url).toBe("/api/payments/withdraw");
    expect(opts.method).toBe("POST");
    expect(JSON.parse(opts.body)).toEqual({
      amount_usd: 10,
      wallet_address: "0xabc123",
    });
  });

  it("throws on failure", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({}, 502));
    await expect(withdraw(5, "0xfoo")).rejects.toThrow("Withdrawal failed (502)");
  });
});

// ---------------------------------------------------------------------------
// redeemInviteCode
// ---------------------------------------------------------------------------

describe("redeemInviteCode", () => {
  it("sends POST with { code } and returns credited/balance", async () => {
    const payload = { credited_usd: "5.00", balance_usd: "15.00" };
    fetchMock.mockResolvedValueOnce(jsonResponse(payload));

    const result = await redeemInviteCode("INV-ABCD1234");

    expect(fetchMock).toHaveBeenCalledOnce();
    const [url, opts] = fetchMock.mock.calls[0];
    expect(url).toBe("/api/invite/redeem");
    expect(opts.method).toBe("POST");
    expect(JSON.parse(opts.body)).toEqual({ code: "INV-ABCD1234" });
    expect(result).toEqual(payload);
  });

  it("throws with server error message on failure", async () => {
    const errorBody = { error: { message: "Code already redeemed" } };
    fetchMock.mockResolvedValueOnce(jsonResponse(errorBody, 409));

    await expect(redeemInviteCode("INV-USED")).rejects.toThrow(
      "Code already redeemed"
    );
  });

  it("falls back to generic message when no error.message", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({}, 500));

    await expect(redeemInviteCode("INV-BAD")).rejects.toThrow(
      "Redemption failed (500)"
    );
  });
});

// ---------------------------------------------------------------------------
// fetchModels
// ---------------------------------------------------------------------------

describe("fetchModels", () => {
  it("calls /api/models and flattens metadata", async () => {
    const raw = {
      data: [
        {
          id: "mlx-community/Llama-3-8B",
          object: "model",
          metadata: {
            model_type: "chat",
            quantization: "4bit",
            provider_count: 3,
            attested_providers: 2,
          },
        },
      ],
    };
    fetchMock.mockResolvedValueOnce(jsonResponse(raw));

    const result = await fetchModels();

    expect(result).toHaveLength(1);
    expect(result[0].model_type).toBe("chat");
    expect(result[0].quantization).toBe("4bit");
    expect(result[0].provider_count).toBe(3);
    expect(result[0].attested).toBe(true);
  });

  it("throws on non-ok response", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({}, 503));
    await expect(fetchModels()).rejects.toThrow("Failed to fetch models: 503");
  });
});

// ---------------------------------------------------------------------------
// fetchPricing
// ---------------------------------------------------------------------------

describe("fetchPricing", () => {
  it("calls /api/pricing and returns pricing data", async () => {
    const payload = {
      prices: [
        { model: "m1", input_price: 100, output_price: 200, input_usd: "0.01", output_usd: "0.02" },
      ],
    };
    fetchMock.mockResolvedValueOnce(jsonResponse(payload));

    const result = await fetchPricing();
    expect(result.prices).toHaveLength(1);
    expect(result.prices[0].model).toBe("m1");
  });
});

// ---------------------------------------------------------------------------
// healthCheck
// ---------------------------------------------------------------------------

describe("healthCheck", () => {
  it("calls /api/health and returns status", async () => {
    const payload = { status: "ok", providers: 5 };
    fetchMock.mockResolvedValueOnce(jsonResponse(payload));

    const result = await healthCheck();
    expect(result).toEqual(payload);
  });

  it("throws on non-ok response", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({}, 500));
    await expect(healthCheck()).rejects.toThrow("Health check failed: 500");
  });
});

// ---------------------------------------------------------------------------
// proxyHeaders
// ---------------------------------------------------------------------------

describe("proxy headers", () => {
  it("includes x-coordinator-url defaulting to public coordinator", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ balance_micro_usd: 0, balance_usd: 0 }));
    await fetchBalance();

    const [, opts] = fetchMock.mock.calls[0];
    expect(opts.headers["x-coordinator-url"]).toContain("darkbloom.dev");
  });

  it("includes x-api-key when set in localStorage", async () => {
    localStorage.setItem("darkbloom_api_key", "test-key-123");
    fetchMock.mockResolvedValueOnce(jsonResponse({ balance_micro_usd: 0, balance_usd: 0 }));
    await fetchBalance();

    const [, opts] = fetchMock.mock.calls[0];
    expect(opts.headers["x-api-key"]).toBe("test-key-123");
  });

  it("omits x-api-key when not set", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ balance_micro_usd: 0, balance_usd: 0 }));
    await fetchBalance();

    const [, opts] = fetchMock.mock.calls[0];
    expect(opts.headers["x-api-key"]).toBeUndefined();
  });
});
