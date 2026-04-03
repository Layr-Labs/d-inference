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
      transcription_prices: [],
      image_prices: [],
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
  fetchMock = vi.fn().mockResolvedValue(
    new Response(JSON.stringify({ providers: [] }), { status: 200 })
  );
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
  it("renders without crashing and shows key elements", async () => {
    const BillingPage = (await import("@/app/billing/page")).default;
    render(<BillingPage />);

    // TopBar is mocked and should show "Billing"
    expect(screen.getByTestId("topbar")).toHaveTextContent("Billing");

    // Deposit and Withdraw buttons should be present
    expect(screen.getByText("Deposit")).toBeInTheDocument();
    expect(screen.getByText("Withdraw")).toBeInTheDocument();

    // Invite code section
    expect(screen.getByText("Invite Code")).toBeInTheDocument();
    expect(screen.getByText("Redeem")).toBeInTheDocument();

    // Stats labels
    expect(screen.getByText("Total Spent")).toBeInTheDocument();
    expect(screen.getByText("Total Tokens")).toBeInTheDocument();
    expect(screen.getByText("Requests")).toBeInTheDocument();
  });

  it("shows usage history section", async () => {
    const BillingPage = (await import("@/app/billing/page")).default;
    render(<BillingPage />);

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
      screen.getByText(/Connect your Mac to your EigenInference account/)
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
  it("renders without crashing and shows network heading", async () => {
    const ProvidersPage = (await import("@/app/providers/page")).default;
    render(<ProvidersPage />);

    // Wait for loading to finish (it does a fetch in useEffect)
    // The fetch mock returns { providers: [] } so it should render quickly
    await screen.findByText("Network Providers");
    expect(screen.getByText("Network Providers")).toBeInTheDocument();
  });

  it("shows summary stats", async () => {
    const ProvidersPage = (await import("@/app/providers/page")).default;
    render(<ProvidersPage />);

    await screen.findByText("Network Providers");
    expect(screen.getByText("Providers")).toBeInTheDocument();
    expect(screen.getByText("Hardware Trust")).toBeInTheDocument();
    expect(screen.getByText("Apple MDA")).toBeInTheDocument();
    expect(screen.getByText("Total Memory")).toBeInTheDocument();
  });

  it("shows 'Become a Provider' button when no matching wallet", async () => {
    const ProvidersPage = (await import("@/app/providers/page")).default;
    render(<ProvidersPage />);

    await screen.findByText("Network Providers");
    expect(screen.getByText("Become a Provider")).toBeInTheDocument();
  });

  it("shows empty state when no providers", async () => {
    const ProvidersPage = (await import("@/app/providers/page")).default;
    render(<ProvidersPage />);

    await screen.findByText("No providers online");
  });
});
