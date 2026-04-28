import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen } from "@testing-library/react";

const authMocks = vi.hoisted(() => ({
  getAccessToken: vi.fn().mockResolvedValue("mock-token"),
  login: vi.fn(),
  logout: vi.fn(),
}));

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
    login: authMocks.login,
    logout: authMocks.logout,
    getAccessToken: authMocks.getAccessToken,
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
    login: authMocks.login,
    logout: authMocks.logout,
    getAccessToken: authMocks.getAccessToken,
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

    // Balance card and Buy Credits button present
    expect(screen.getByText("Balance")).toBeInTheDocument();
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
// API Console page
// =========================================================================

describe("ApiConsolePage", () => {
  it("renders routing preference examples", async () => {
    const ApiConsolePage = (await import("@/app/api-console/page")).default;
    render(<ApiConsolePage />);

    expect(screen.getByText("Routing Preference")).toBeInTheDocument();
    expect(screen.getByText("JSON Body")).toBeInTheDocument();
    expect(screen.getByText("Header")).toBeInTheDocument();
    expect(screen.getByText("Query Param")).toBeInTheDocument();
    expect(screen.getAllByText(/routing_preference/).length).toBeGreaterThan(0);
  });
});

// =========================================================================
// Providers page
// =========================================================================

describe("ProvidersPage", () => {
  it("renders without crashing and shows dashboard heading", async () => {
    const ProvidersPage = (await import("@/app/providers/page")).default;
    render(<ProvidersPage />);

    await screen.findByRole("heading", { name: "Provider Dashboard" });
    expect(screen.getByText("Your linked provider machines.")).toBeInTheDocument();
  });

  it("shows the rebuild notice", async () => {
    const ProvidersPage = (await import("@/app/providers/page")).default;
    render(<ProvidersPage />);

    await screen.findByText("We're rebuilding this page");
    expect(screen.getByText(/Detailed machine stats/)).toBeInTheDocument();
  });

  it("shows onboarding actions when no devices are linked", async () => {
    const ProvidersPage = (await import("@/app/providers/page")).default;
    render(<ProvidersPage />);

    await screen.findByText("No provider devices linked yet");
    expect(screen.getByText("Set up a provider")).toBeInTheDocument();
    expect(screen.getByText("Open calculator")).toBeInTheDocument();
  });
});
