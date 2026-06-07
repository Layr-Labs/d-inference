import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen } from "@testing-library/react";

// ---------------------------------------------------------------------------
// Mock modules used by page components. We mock at the module level so the
// pages can import them without hitting Privy, Zustand persistence, etc.
// ---------------------------------------------------------------------------

// Mock @/hooks/useToast — provides addToast
vi.mock("@/hooks/useToast", () => ({
  useToastStore: () => vi.fn(),
}));

// Mock @/lib/store — provides useStore for TopBar and chat state
vi.mock("@/lib/store", () => ({
  useStore: () => ({
    sidebarOpen: false,
    setSidebarOpen: vi.fn(),
    chats: [],
    activeChatId: null,
    selectedModel: "",
    models: [],
  }),
}));

// Mock @/hooks/useAuth — provides walletAddress etc
vi.mock("@/hooks/useAuth", () => ({
  useAuth: () => ({
    ready: true,
    authenticated: true,
    user: null,
    login: vi.fn(),
    logout: vi.fn(),
    getAccessToken: vi.fn().mockResolvedValue("mock-token"),
    email: null,
    walletAddress: null,
    displayName: null,
  }),
}));

// Mock @/components/providers/PrivyClientProvider
vi.mock("@/components/providers/PrivyClientProvider", () => ({
  useAuthContext: () => ({
    ready: true,
    authenticated: true,
    user: null,
    login: vi.fn(),
    logout: vi.fn(),
    getAccessToken: vi.fn().mockResolvedValue("mock-token"),
  }),
}));

// Mock Privy Solana hooks — BillingContent uses them directly, and they
// panic without a PrivyProvider wrapper.
vi.mock("@privy-io/react-auth/solana", () => ({
  useWallets: () => ({ wallets: [] }),
  useSignAndSendTransaction: () => ({ signAndSendTransaction: vi.fn() }),
}));

// Mock @/lib/api — prevent real fetches
vi.mock("@/lib/api", async (importOriginal) => {
  const actual = (await importOriginal()) as Record<string, unknown>;
  return {
    ...actual,
    fetchBalance: vi.fn().mockResolvedValue({
      balance_micro_usd: 10_000_000,
      balance_usd: 10.0,
    }),
    fetchUsage: vi.fn().mockResolvedValue([]),
    deposit: vi.fn().mockResolvedValue(undefined),
    withdraw: vi.fn().mockResolvedValue(undefined),
    redeemInviteCode: vi.fn().mockResolvedValue({
      credited_usd: "5.00",
      balance_usd: "15.00",
    }),
    fetchModels: vi.fn().mockResolvedValue([]),
    fetchPricing: vi.fn().mockResolvedValue({
      prices: [],
    }),
    healthCheck: vi.fn().mockResolvedValue({ status: "ok", providers: 0 }),
  };
});

// Mock @/components/TopBar
vi.mock("@/components/TopBar", () => ({
  TopBar: ({ title }: { title?: string }) => (
    <div data-testid="topbar">{title}</div>
  ),
}));

// Mock @/components/UsageChart
vi.mock("@/components/UsageChart", () => ({
  UsageChart: () => <div data-testid="usage-chart" />,
}));

// Stub global fetch for any stray calls
let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  fetchMock = vi.fn((input: RequestInfo | URL) => {
    const url = String(input);
    if (url.includes("/api/me/providers")) {
      return Promise.resolve(
        new Response(
          JSON.stringify({
            providers: [],
            latest_provider_version: "0.3.10",
            min_provider_version: "0.3.10",
            heartbeat_timeout_seconds: 90,
            challenge_max_age_seconds: 360,
          }),
          { status: 200 }
        )
      );
    }
    if (url.includes("/api/me/summary")) {
      return Promise.resolve(
        new Response(
          JSON.stringify({
            account_id: "acct-test",
            available_balance_micro_usd: 0,
            withdrawable_balance_micro_usd: 0,
            payout_ready: false,
            lifetime_micro_usd: 0,
            lifetime_jobs: 0,
            last_24h_micro_usd: 0,
            last_24h_jobs: 0,
            last_7d_micro_usd: 0,
            last_7d_jobs: 0,
            counts: {
              total: 0,
              online: 0,
              serving: 0,
              offline: 0,
              untrusted: 0,
              hardware: 0,
              needs_attention: 0,
            },
            latest_provider_version: "0.3.10",
            min_provider_version: "0.3.10",
          }),
          { status: 200 }
        )
      );
    }
    return Promise.resolve(
      new Response(JSON.stringify({ providers: [] }), { status: 200 })
    );
  });
  vi.stubGlobal("fetch", fetchMock);

  localStorage.clear();
});

afterEach(() => {
  vi.restoreAllMocks();
});

// =========================================================================
// Billing page
// =========================================================================

describe("BillingPage", () => {
  // page.tsx wraps BillingContent in next/dynamic({ ssr: false }), whose
  // loading fallback never resolves in vitest. Import the content component
  // directly so the test actually renders the UI under test.
  it("renders without crashing and shows key elements", async () => {
    const BillingContent = (await import("@/app/billing/BillingContent")).default;
    render(<BillingContent />);

    // TopBar is mocked and should show "Billing"
    expect(screen.getByTestId("topbar")).toHaveTextContent("Billing");

    // Balance card — starts in loading state and exposes Buy Credits action.
    expect(screen.getByText("Balance")).toBeInTheDocument();
    expect(screen.getByText("Loading...")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Buy Credits/i })).toBeInTheDocument();

    // Invite code section
    expect(screen.getByText("Invite Code")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Redeem/i })).toBeInTheDocument();

    // Stats labels
    expect(screen.getByText("Total Spent")).toBeInTheDocument();
    expect(screen.getByText("Total Tokens")).toBeInTheDocument();
    expect(screen.getByText("Requests")).toBeInTheDocument();
  });

  it("shows usage history section", async () => {
    const BillingContent = (await import("@/app/billing/BillingContent")).default;
    render(<BillingContent />);

    expect(screen.getByText("Usage History")).toBeInTheDocument();
  });
});

// =========================================================================
// Link page
// =========================================================================

describe("LinkPage", () => {
  it("renders without crashing and shows heading", async () => {
    const LinkPage = (await import("@/app/link/page")).default;
    render(<LinkPage />);

    expect(screen.getByText("Link Your Device")).toBeInTheDocument();
    expect(
      screen.getByText(/Connect your Mac to your Darkbloom account/)
    ).toBeInTheDocument();
  });

  it("shows the device code input form when authenticated", async () => {
    const LinkPage = (await import("@/app/link/page")).default;
    render(<LinkPage />);

    // The DeviceLinkForm renders code input when authenticated
    expect(
      screen.getByText("Enter the code shown in your terminal")
    ).toBeInTheDocument();
    expect(screen.getByPlaceholderText("XXXX-XXXX")).toBeInTheDocument();
    expect(screen.getByText("Link Device")).toBeInTheDocument();
  });
});

// =========================================================================
// Providers page
// =========================================================================

describe("ProvidersPage", () => {
  it("shows onboarding actions when no machines are linked", async () => {
    const ProvidersPage = (await import("@/app/providers/page")).default;
    render(<ProvidersPage />);

    await screen.findByText("No provider machines linked yet");
    expect(screen.getByText("Set up a provider")).toBeInTheDocument();
    expect(screen.getByText("Open calculator")).toBeInTheDocument();
  });

  it("renders the fleet, verdict, and a machine card when a machine is linked", async () => {
    const healthy = {
      id: "m1",
      account_id: "acct-test",
      status: "serving",
      online: true,
      hardware: { chip_name: "Apple M3 Max", memory_gb: 64, gpu_cores: 40 },
      models: [{ id: "mlx-community/Qwen3.5-9B-MLX-4bit" }],
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
      failed_challenges: 0,
      pending_requests: 1,
      max_concurrency: 8,
      decode_tps: 50,
      system_metrics: { memory_pressure: 0.3, cpu_usage: 0.2, thermal_state: "nominal" },
      reputation: {
        score: 0.9, total_jobs: 100, successful_jobs: 99, failed_jobs: 1,
        total_uptime_seconds: 3600, avg_response_time_ms: 200, challenges_passed: 5, challenges_failed: 0,
      },
      lifetime_requests_served: 100,
      lifetime_tokens_generated: 1_000_000,
      earnings_total_micro_usd: 5_000_000,
      earnings_count: 100,
      version: "0.3.10",
      last_challenge_verified: new Date().toISOString(),
    };
    vi.stubGlobal(
      "fetch",
      vi.fn((input: RequestInfo | URL) => {
        const url = String(input);
        if (url.includes("/api/me/providers")) {
          return Promise.resolve(
            new Response(
              JSON.stringify({
                providers: [healthy],
                latest_provider_version: "0.3.10",
                min_provider_version: "0.3.10",
                heartbeat_timeout_seconds: 90,
                challenge_max_age_seconds: 360,
              }),
              { status: 200 }
            )
          );
        }
        if (url.includes("/api/me/summary")) {
          return Promise.resolve(
            new Response(
              JSON.stringify({
                account_id: "acct-test",
                available_balance_micro_usd: 5_000_000,
                withdrawable_balance_micro_usd: 5_000_000,
                payout_ready: true,
                lifetime_micro_usd: 5_000_000,
                lifetime_jobs: 100,
                last_24h_micro_usd: 1_000_000,
                last_24h_jobs: 20,
                last_7d_micro_usd: 5_000_000,
                last_7d_jobs: 100,
                counts: { total: 1, online: 0, serving: 1, offline: 0, untrusted: 0, hardware: 1, needs_attention: 0 },
                latest_provider_version: "0.3.10",
                min_provider_version: "0.3.10",
              }),
              { status: 200 }
            )
          );
        }
        return Promise.resolve(new Response(JSON.stringify({ providers: [] }), { status: 200 }));
      })
    );

    const ProvidersPage = (await import("@/app/providers/page")).default;
    render(<ProvidersPage />);

    await screen.findByText("Apple M3 Max");
    expect(screen.getByRole("heading", { name: "Fleet" })).toBeInTheDocument();
    expect(
      screen.getByText("All clear — every machine is routable and earning.")
    ).toBeInTheDocument();
  });

  it("surfaces problems: attention feed, NOT-EARNING verdict, and a fix for a mixed fleet", async () => {
    const machine = (over: Record<string, unknown>) => ({
      id: "x",
      account_id: "acct-test",
      status: "online",
      online: true,
      hardware: { chip_name: "Apple M2", memory_gb: 32, gpu_cores: 19 },
      models: [{ id: "mlx-community/Qwen3.5-9B-MLX-4bit" }],
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
      failed_challenges: 0,
      pending_requests: 0,
      max_concurrency: 8,
      reputation: {
        score: 0.8, total_jobs: 50, successful_jobs: 49, failed_jobs: 1,
        total_uptime_seconds: 3600, avg_response_time_ms: 250, challenges_passed: 5, challenges_failed: 0,
      },
      lifetime_requests_served: 50,
      lifetime_tokens_generated: 500_000,
      earnings_total_micro_usd: 1_000_000,
      earnings_count: 50,
      version: "0.3.10",
      last_challenge_verified: new Date().toISOString(),
      ...over,
    });

    const blocked = machine({ id: "b1", trust_level: "self_signed", hardware: { chip_name: "Apple M2", memory_gb: 32 } });
    const offline = machine({ id: "o1", status: "offline", online: false, hardware: { chip_name: "Mac Studio", memory_gb: 192 } });

    vi.stubGlobal(
      "fetch",
      vi.fn((input: RequestInfo | URL) => {
        const url = String(input);
        if (url.includes("/api/me/providers")) {
          return Promise.resolve(
            new Response(
              JSON.stringify({
                providers: [blocked, offline],
                latest_provider_version: "0.3.10",
                min_provider_version: "0.3.10",
                heartbeat_timeout_seconds: 90,
                challenge_max_age_seconds: 360,
              }),
              { status: 200 }
            )
          );
        }
        return Promise.resolve(new Response(JSON.stringify({ providers: [] }), { status: 200 }));
      })
    );

    const ProvidersPage = (await import("@/app/providers/page")).default;
    render(<ProvidersPage />);

    // Attention feed renders for an unhealthy fleet (not the all-clear strip).
    await screen.findByText("Needs attention");
    expect(
      screen.queryByText("All clear — every machine is routable and earning.")
    ).not.toBeInTheDocument();
    // The blocked machine's card shows the NOT-EARNING hero verb.
    expect(screen.getAllByText(/NOT EARNING/i).length).toBeGreaterThan(0);
    // The offline machine surfaces its start command as the fix.
    expect(screen.getAllByText("darkbloom start").length).toBeGreaterThan(0);
  });
});
