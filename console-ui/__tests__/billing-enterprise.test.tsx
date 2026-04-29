import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";

const enterpriseMock = vi.hoisted(() => ({ response: {} as Record<string, unknown> }));
const aprilFirst = "2026-04-01T00:00:00Z";

vi.mock("@/hooks/useToast", () => ({
  useToastStore: () => vi.fn(),
}));

vi.mock("@/hooks/useAuth", () => ({
  useAuth: () => ({ email: "user@example.com" }),
}));

vi.mock("@/components/TopBar", () => ({
  TopBar: ({ title }: { title?: string }) => <div>{title}</div>,
}));

vi.mock("@/components/UsageChart", () => ({
  UsageChart: () => <div data-testid="usage-chart" />,
}));

vi.mock("@/lib/api", async (importOriginal) => {
  const actual = (await importOriginal()) as Record<string, unknown>;
  return {
    ...actual,
    fetchBalance: vi.fn().mockResolvedValue({
      balance_micro_usd: 0,
      balance_usd: 0,
      withdrawable_micro_usd: 0,
      withdrawable_usd: 0,
    }),
    fetchUsage: vi.fn().mockResolvedValue([]),
    fetchEnterpriseStatus: vi.fn().mockImplementation(() => Promise.resolve(enterpriseMock.response)),
    fetchStripeStatus: vi.fn().mockResolvedValue({ configured: false, has_account: false, status: "" }),
    fetchStripeWithdrawals: vi.fn().mockResolvedValue([]),
    createStripeCheckout: vi.fn(),
    redeemInviteCode: vi.fn(),
  };
});

beforeEach(() => {
  enterpriseMock.response = {
      enabled: true,
      credit_remaining_micro_usd: 7_500_000,
      account: {
        account_id: "acct-ent",
        status: "active",
        billing_email: "billing@example.com",
        cadence: "biweekly",
        terms_days: 15,
        credit_limit_micro_usd: 10_000_000,
        accrued_micro_usd: 2_000_000,
        reserved_micro_usd: 500_000,
        open_invoice_micro_usd: 0,
        rounding_carry_micro_usd: 0,
        current_period_start: aprilFirst,
        next_invoice_at: "2026-04-15T00:00:00Z",
      },
      recent_invoices: [
        {
          id: "inv-1",
          status: "open",
          amount_micro_usd: 3_000_000,
          amount_cents: 300,
          terms_days: 15,
          period_start: "2026-03-15T00:00:00Z",
          period_end: aprilFirst,
          stripe_hosted_invoice_url: "https://invoice.test/inv-1",
        },
      ],
    };
  const store = new Map<string, string>();
  vi.stubGlobal("localStorage", {
    getItem: (k: string) => store.get(k) ?? null,
    setItem: (k: string, v: string) => {
      store.set(k, v);
    },
    removeItem: (k: string) => {
      store.delete(k);
    },
  });
});

afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllGlobals();
});

describe("Billing Enterprise card", () => {
  it("shows cadence, editable terms, remaining credit, and invoice link", async () => {
    const BillingContent = (await import("@/app/billing/BillingContent")).default;
    render(<BillingContent />);

    await waitFor(() => {
      expect(screen.getByText("Enterprise Invoicing")).toBeInTheDocument();
    });
    expect(screen.getByText("Bi-weekly")).toBeInTheDocument();
    expect(screen.getByText("Net 15")).toBeInTheDocument();
    expect(screen.getByText("$7.50 / $10.00")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /View invoice/i })).toHaveAttribute(
      "href",
      "https://invoice.test/inv-1",
    );
  });

  it("shows disabled enterprise accounts with invoice history", async () => {
    enterpriseMock.response = {
      enabled: false,
      credit_remaining_micro_usd: 7_000_000,
      account: {
        account_id: "acct-ent",
        status: "disabled",
        billing_email: "billing@example.com",
        stripe_customer_id: "cus_ent",
        cadence: "monthly",
        terms_days: 30,
        credit_limit_micro_usd: 10_000_000,
        accrued_micro_usd: 1_000_000,
        reserved_micro_usd: 0,
        open_invoice_micro_usd: 2_000_000,
        rounding_carry_micro_usd: 0,
        current_period_start: aprilFirst,
        next_invoice_at: "2026-05-01T00:00:00Z",
      },
      recent_invoices: [
        {
          id: "inv-disabled",
          status: "open",
          amount_micro_usd: 2_000_000,
          amount_cents: 200,
          terms_days: 30,
          period_start: "2026-03-01T00:00:00Z",
          period_end: aprilFirst,
          stripe_hosted_invoice_url: "https://invoice.test/inv-disabled",
        },
      ],
    };
    const BillingContent = (await import("@/app/billing/BillingContent")).default;
    render(<BillingContent />);

    await waitFor(() => {
      expect(screen.getByText("Enterprise Invoicing")).toBeInTheDocument();
    });
    expect(screen.getByText("Disabled")).toBeInTheDocument();
    expect(screen.getByText("Net 30")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /View invoice/i })).toHaveAttribute(
      "href",
      "https://invoice.test/inv-disabled",
    );
  });
});
