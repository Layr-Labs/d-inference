import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  fetchBalance,
  fetchUsage,
  createStripeCheckout,
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

  localStorage.clear();
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
    expect(opts.headers["x-api-key"]).toBeUndefined();
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
// createStripeCheckout
// ---------------------------------------------------------------------------

describe("createStripeCheckout", () => {
  it("sends POST to /api/payments/stripe/checkout with amount_usd", async () => {
    const payload = { url: "https://checkout.stripe.com/session/123", session_id: "cs_123" };
    fetchMock.mockResolvedValueOnce(jsonResponse(payload));

    const result = await createStripeCheckout("10");

    expect(fetchMock).toHaveBeenCalledOnce();
    const [url, opts] = fetchMock.mock.calls[0];
    expect(url).toBe("/api/payments/stripe/checkout");
    expect(opts.method).toBe("POST");
    expect(JSON.parse(opts.body)).toEqual({ amount_usd: "10" });
    expect(result).toEqual(payload);
  });

  it("includes email when provided", async () => {
    const payload = { url: "https://checkout.stripe.com/session/456", session_id: "cs_456" };
    fetchMock.mockResolvedValueOnce(jsonResponse(payload));

    await createStripeCheckout("5", "test@example.com");

    const [, opts] = fetchMock.mock.calls[0];
    expect(JSON.parse(opts.body)).toEqual({ amount_usd: "5", email: "test@example.com" });
  });

  it("throws on failure", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({}, 400));
    await expect(createStripeCheckout("0")).rejects.toThrow("Checkout failed (400)");
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

  it("unwraps the public catalog response shape", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({
      models: [
        {
          id: "gpt-oss-20b",
          display_name: "GPT-OSS 20B",
          size_gb: 12.1,
          min_ram_gb: 24,
          architecture: "MoE",
        },
      ],
    }));

    const result = await fetchModels();

    expect(result).toHaveLength(1);
    expect(result[0].id).toBe("gpt-oss-20b");
    expect(result[0].display_name).toBe("GPT-OSS 20B");
    expect(result[0].min_ram_gb).toBe(24);
  });

  it("surfaces OpenRouter provider fields (pricing, modalities, features)", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({
      data: [
        {
          id: "mlx-community/Qwen3.5-9B-MLX-4bit",
          object: "model",
          name: "Qwen3.5 9B",
          hugging_face_id: "mlx-community/Qwen3.5-9B-MLX-4bit",
          created: 1735689600,
          description: "Balanced general-purpose model.",
          context_length: 262144,
          quantization: "int4",
          pricing: { prompt: "0.00000005", completion: "0.0000002", image: "0", request: "0", input_cache_read: "0" },
          input_modalities: ["text"],
          output_modalities: ["text"],
          supported_features: ["tools", "reasoning"],
          supported_sampling_parameters: ["temperature", "top_p", "max_tokens"],
          metadata: {},
        },
      ],
    }));

    const result = await fetchModels();

    expect(result).toHaveLength(1);
    const m = result[0];
    expect(m.name).toBe("Qwen3.5 9B");
    expect(m.hugging_face_id).toBe("mlx-community/Qwen3.5-9B-MLX-4bit");
    expect(m.created).toBe(1735689600);
    expect(m.description).toBe("Balanced general-purpose model.");
    expect(m.context_length).toBe(262144);
    expect(m.pricing?.prompt).toBe("0.00000005");
    expect(m.pricing?.completion).toBe("0.0000002");
    expect(m.input_modalities).toEqual(["text"]);
    expect(m.output_modalities).toEqual(["text"]);
    expect(m.supported_features).toEqual(["tools", "reasoning"]);
    expect(m.supported_sampling_parameters).toContain("temperature");
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
  it("does not include x-coordinator-url (server-side only)", async () => {
    fetchMock.mockResolvedValueOnce(jsonResponse({ balance_micro_usd: 0, balance_usd: 0 }));
    await fetchBalance();

    const [, opts] = fetchMock.mock.calls[0];
    expect(opts.headers["x-coordinator-url"]).toBeUndefined();
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
