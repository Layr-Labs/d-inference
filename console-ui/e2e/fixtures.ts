import { test as base, expect, type Page } from "@playwright/test";

// Hermetic auth + API fixture for authenticated-flow E2E. The app runs with
// NEXT_PUBLIC_E2E_AUTH=1 (mock-auth returns a usable token+user), and every
// coordinator-proxy call (/api/*) is route-mocked here with seeded data, so the
// suite drives real authenticated flows without a Privy tenant or coordinator.

export const SEED_MODEL = {
  id: "qwen3.5-9b-mlx-4bit",
  object: "model",
  display_name: "Qwen 3.5 9B",
  model_type: "chat",
};

// A vision-capable model: the composer's image-attach control is gated on
// `modelSupportsImages`, which keys off `input_modalities` containing "image"
// (see src/lib/image-upload.ts). Seed this as the only model so the store
// auto-selects it and the upload affordance appears.
export const SEED_VISION_MODEL = {
  id: "gemma-4-26b-mlx",
  object: "model",
  display_name: "Gemma 4 26B",
  model_type: "chat",
  input_modalities: ["text", "image"],
};

// Minimal-but-valid MyProvider (mirrors src/app/providers/types.ts). Loosely
// typed on purpose so the fixture stays decoupled from app types.
export function makeProvider(overrides: Record<string, unknown> = {}) {
  return {
    id: "prov-e2e-1",
    account_id: "e2e-user",
    status: "online",
    online: true,
    last_heartbeat: new Date().toISOString(),
    hardware: { machine_model: "Mac15,8", chip_name: "Apple M3 Max", chip_family: "M3", memory_gb: 64 },
    models: [{ id: SEED_MODEL.id, model_type: "chat", quantization: "4bit" }],
    backend: "mlx-swift",
    version: "0.6.20",
    serial_number: "E2E-SERIAL-1",
    trust_level: "hardware",
    attested: true,
    mda_verified: true,
    acme_verified: true,
    se_key_bound: true,
    secure_enclave: true,
    sip_enabled: true,
    secure_boot_enabled: true,
    authenticated_root_enabled: true,
    runtime_verified: true,
    last_challenge_verified: new Date().toISOString(),
    failed_challenges: 0,
    pending_requests: 0,
    max_concurrency: 8,
    reputation: {
      score: 0.95,
      total_jobs: 10,
      successful_jobs: 10,
      failed_jobs: 0,
      total_uptime_seconds: 3600,
      avg_response_time_ms: 250,
      challenges_passed: 12,
      challenges_failed: 0,
    },
    lifetime_requests_served: 10,
    lifetime_tokens_generated: 1000,
    ...overrides,
  };
}

export function makeProvidersResponse(providers: unknown[]) {
  return {
    providers,
    latest_provider_version: "0.6.20",
    min_provider_version: "0.6.0",
    heartbeat_timeout_seconds: 90,
    challenge_max_age_seconds: 360,
  };
}

// Minimal-but-valid PlatformStats (mirrors the interface in stats/page.tsx).
// Empty providers/models/time_series keep the network map + charts inert while
// the hero/mini stat cards still render from the scalar totals.
export function makeStats(overrides: Record<string, unknown> = {}) {
  return {
    total_requests: 4242,
    total_prompt_tokens: 5_000_000,
    total_completion_tokens: 1_500_000,
    total_tokens: 6_500_000,
    avg_tokens_per_request: 1532,
    active_providers: 0,
    total_gpu_cores: 0,
    total_cpu_cores: 0,
    total_memory_gb: 0,
    total_bandwidth_gbs: 0,
    network_capacity_tps: 0,
    network_utilization: { utilization: 0 },
    providers: [],
    models: [],
    time_series: [],
    ...overrides,
  };
}

// A single priced catalog entry in the coordinator's pricing shape (prices[].
// model / input_price / output_price are micro-USD per 1M tokens).
export function makePrice(model: string, inputMicro = 100_000, outputMicro = 300_000) {
  return { model, input_price: inputMicro, output_price: outputMicro };
}

// Minimal leaderboard + network-totals payloads (mirrors stats/page.tsx).
export function makeLeaderboardEntry(overrides: Record<string, unknown> = {}) {
  return {
    rank: 1,
    pseudonym: "e2e-provider-1",
    earnings_micro_usd: 5_000_000,
    work_earnings_micro_usd: 4_000_000,
    reward_earnings_micro_usd: 1_000_000,
    tokens: 2_500_000,
    jobs: 42,
    ...overrides,
  };
}

export function makeLeaderboard(
  metric: "earnings" | "tokens" | "jobs" = "earnings",
  window: "24h" | "7d" | "30d" | "all" = "7d",
  entries: unknown[] = [makeLeaderboardEntry()],
) {
  return {
    metric,
    window,
    entries,
    updated_at: new Date().toISOString(),
  };
}

export function makeNetworkTotals(window: "24h" | "7d" | "30d" | "all" = "7d", overrides: Record<string, unknown> = {}) {
  return {
    window,
    earnings_micro_usd: 5_000_000,
    work_earnings_micro_usd: 4_000_000,
    reward_earnings_micro_usd: 1_000_000,
    tokens: 2_500_000,
    jobs: 42,
    active_accounts: 3,
    updated_at: new Date().toISOString(),
    ...overrides,
  };
}

// A valid 32-byte X25519 public key (all 0x07) for encryption-key success mocks.
export const E2E_COORD_PUB_B64 = btoa(String.fromCharCode(...new Uint8Array(32).fill(7)));

const EMPTY_SUMMARY = {
  account_id: "e2e-user",
  available_balance_micro_usd: 0,
  lifetime_micro_usd: 0,
  lifetime_jobs: 0,
  last_24h_micro_usd: 0,
  last_24h_jobs: 0,
  last_7d_micro_usd: 0,
  last_7d_jobs: 0,
  counts: { total: 0, online: 0, serving: 0, offline: 0, untrusted: 0, hardware: 0, needs_attention: 0 },
  latest_provider_version: "0.6.20",
  min_provider_version: "0.6.0",
};

function makeKey(over: Record<string, unknown> = {}) {
  return {
    id: "key_1",
    name: "Default key",
    label: "sk-db-1a2b...c3d4",
    disabled: false,
    limit_reset: "none",
    usage_usd: 0,
    created_at: "2026-06-01T00:00:00Z",
    ...over,
  };
}

export function chatSse(chunks: string[]): string {
  const out = chunks.map(
    (c) => `data: ${JSON.stringify({ choices: [{ delta: { content: c } }] })}\n\n`,
  );
  out.push("data: [DONE]\n\n");
  return out.join("");
}

// Default streamed assistant response used by the chat flows.
export const CHAT_REPLY = "Hello from the E2E mock";

async function installCoordinatorMocks(page: Page) {
  await page.route("**/api/auth/keys", (route) =>
    route.fulfill({ json: { api_key: "sk-db-e2e-provisioned", account_id: "e2e-user" } }),
  );
  await page.route("**/api/models", (route) =>
    route.fulfill({ json: { object: "list", data: [SEED_MODEL] } }),
  );
  await page.route("**/api/pricing", (route) => route.fulfill({ json: { prices: [] } }));
  await page.route("**/api/health", (route) => route.fulfill({ json: { status: "ok" } }));

  // Network stats (overview). The stats page also calls model catalog/capacity:
  // /api/models is already mocked above; capacity has no proxy fixture, so 404 it
  // and 404 the COORDINATOR_URL `/v1/models/{catalog,capacity}` fallback too, so
  // the page degrades to null (its documented behaviour) without a real network
  // call. Catalog/capacity failures don't reject the page's Promise.all — only a
  // failed /api/stats does — so a successful stats render needs only this mock.
  await page.route(/\/api\/stats(\?.*)?$/, (route) => route.fulfill({ json: makeStats() }));
  await page.route(/\/api\/leaderboard(\?.*)?$/, (route) =>
    route.fulfill({ json: makeLeaderboard() }),
  );
  await page.route(/\/api\/network\/totals(\?.*)?$/, (route) =>
    route.fulfill({ json: makeNetworkTotals() }),
  );
  await page.route("**/api/models/capacity", (route) => route.fulfill({ status: 404, body: "" }));
  await page.route(/\/v1\/models\/(catalog|capacity)/, (route) =>
    route.fulfill({ status: 404, body: "" }),
  );

  // Device linking (RFC 8628 approve). Success by default; the error-path test
  // overrides this with a 400.
  await page.route("**/api/device/approve", (route) => route.fulfill({ json: { ok: true } }));

  // Payments (billing page): balance, usage, Stripe payouts status, and a
  // checkout that "redirects" back to the success URL so the flow completes
  // hermetically (the app does window.location = resp.url).
  await page.route("**/api/payments/balance", (route) =>
    route.fulfill({
      json: { balance_micro_usd: 12_340_000, balance_usd: 12.34, withdrawable_micro_usd: 0, withdrawable_usd: 0 },
    }),
  );
  await page.route("**/api/payments/usage", (route) => route.fulfill({ json: { usage: [] } }));
  await page.route("**/api/payments/stripe/status", (route) =>
    route.fulfill({ json: { configured: false, has_account: false, status: "" } }),
  );
  await page.route("**/api/payments/stripe/checkout", (route) =>
    route.fulfill({ json: { url: "/billing?stripe_checkout_success=1" } }),
  );
  await page.route("**/api/encryption-key", (route) => route.fulfill({ status: 404, body: "" }));
  await page.route("**/api/me/providers", (route) => route.fulfill({ json: makeProvidersResponse([]) }));
  await page.route("**/api/me/summary", (route) => route.fulfill({ json: EMPTY_SUMMARY }));

  // Stateful API-key store: full CRUD so every management flow (create, edit,
  // disable/enable, rotate, revoke) round-trips. All mutations refetch GET, so
  // this array is the single source of truth the UI re-reads after each change.
  const keys: Record<string, unknown>[] = [makeKey()];
  const keyIdFromUrl = (url: string, suffix = "") =>
    decodeURIComponent(url.split("/api/keys/")[1].split("?")[0]).replace(suffix, "");

  // list (GET) + create (POST)
  await page.route(/\/api\/keys(\?.*)?$/, async (route) => {
    const req = route.request();
    if (req.method() === "POST") {
      const body = JSON.parse(req.postData() || "{}") as Record<string, unknown>;
      const created = makeKey({
        ...body,
        id: `key_${keys.length + 1}`,
        name: (body.name as string) || "New key",
        label: "sk-db-new9...z0z0",
      });
      keys.push(created);
      return route.fulfill({ json: { key: "sk-db-e2e-created-secret", data: created } });
    }
    return route.fulfill({ json: { object: "list", data: keys } });
  });

  // edit (PATCH) + revoke (DELETE) by id. Registered after the list route and
  // before the rotate route so Playwright's last-registered-first matching tries
  // rotate, then this, then list — i.e. most specific first.
  await page.route(/\/api\/keys\/[^/]+$/, async (route) => {
    const req = route.request();
    const idx = keys.findIndex((k) => k.id === keyIdFromUrl(req.url()));
    if (req.method() === "DELETE") {
      if (idx >= 0) keys.splice(idx, 1);
      return route.fulfill({ status: 200, json: { ok: true } });
    }
    if (req.method() === "PATCH") {
      const body = JSON.parse(req.postData() || "{}") as Record<string, unknown>;
      if (idx >= 0) keys[idx] = { ...keys[idx], ...body };
      return route.fulfill({ json: keys[idx] ?? makeKey() });
    }
    return route.fallback();
  });

  // rotate (POST .../rotate) — issue a new secret, keep the same id.
  await page.route(/\/api\/keys\/[^/]+\/rotate$/, async (route) => {
    const idx = keys.findIndex((k) => k.id === keyIdFromUrl(route.request().url(), "/rotate"));
    const rotated = makeKey({ ...(keys[idx] ?? {}), label: "sk-db-rot8...w9w9" });
    if (idx >= 0) keys[idx] = rotated;
    return route.fulfill({ json: { key: "sk-db-e2e-rotated-secret", data: rotated } });
  });

  await page.route("**/api/chat", (route) =>
    route.fulfill({
      status: 200,
      headers: { "content-type": "text/event-stream" },
      body: chatSse(CHAT_REPLY.split(" ").map((w, i) => (i === 0 ? w : ` ${w}`))),
    }),
  );
}

export const test = base.extend({
  page: async ({ page }, use) => {
    await installCoordinatorMocks(page);
    await use(page);
  },
});

export { expect };

// Override the providers endpoint for a single test (registered after the
// default, so Playwright runs it first).
export async function seedProviders(page: Page, providers: unknown[]) {
  await page.route("**/api/me/providers", (route) =>
    route.fulfill({ json: makeProvidersResponse(providers) }),
  );
}

// Override the API-key list for a single test (e.g. seed an empty list to drive
// the empty state). Mutations fall through to the stateful default handler.
export async function seedKeys(page: Page, keys: unknown[]) {
  await page.route(/\/api\/keys(\?.*)?$/, (route) => {
    if (route.request().method() !== "GET") return route.fallback();
    return route.fulfill({ json: { object: "list", data: keys } });
  });
}

// Override the model catalog for a single test (e.g. seed two models to drive
// the chat model selector).
export async function seedModels(page: Page, models: unknown[]) {
  await page.route("**/api/models", (route) =>
    route.fulfill({ json: { object: "list", data: models } }),
  );
}

// Override the pricing table for a single test (the default is an empty list).
export async function seedPricing(page: Page, prices: unknown[]) {
  await page.route("**/api/pricing", (route) => route.fulfill({ json: { prices } }));
}

export async function seedLeaderboard(
  page: Page,
  leaderboard = makeLeaderboard(),
  totals = makeNetworkTotals(),
) {
  await page.route(/\/api\/leaderboard(\?.*)?$/, (route) => route.fulfill({ json: leaderboard }));
  await page.route(/\/api\/network\/totals(\?.*)?$/, (route) => route.fulfill({ json: totals }));
}
