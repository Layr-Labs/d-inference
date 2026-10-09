import type { BankWithdrawalQuote, StripeStatus, StripeWithdrawal } from "@/lib/api";

export type WithdrawMethod = "standard" | "instant";

export interface UseStripePayouts {
  status: StripeStatus | null;
  withdrawals: StripeWithdrawal[];
  onboardLoading: boolean;
  selectedCountry: string;
  setSelectedCountry: (c: string) => void;
  withdrawOpen: boolean;
  setWithdrawOpen: (open: boolean) => void;
  withdrawAmount: string;
  setWithdrawAmount: (v: string) => void;
  withdrawMethod: WithdrawMethod;
  setWithdrawMethod: (m: WithdrawMethod) => void;
  withdrawLoading: boolean;
  withdrawQuote: BankWithdrawalQuote | null;
  withdrawConfirmationPending: boolean;
  /** Refetch Stripe status + withdrawal history (refresh=1 pulls live). */
  reload: (refresh?: boolean) => Promise<void>;
  /** Start or continue Stripe-hosted bank setup for the selected country. */
  onboard: () => Promise<void>;
  /** Submit a withdrawal for the current amount + method. */
  withdraw: () => Promise<void>;
  /** Open the withdraw modal, seeding the amount + best available method. */
  openWithdraw: (defaultAmount?: string) => void;
  /** Open Stripe-hosted settings to change the payout bank account. */
  openDashboard: () => Promise<void>;
  dashboardLoading: boolean;
  /** Detach the linked Stripe account so a fresh one can be onboarded. */
  unlink: () => Promise<void>;
  unlinkLoading: boolean;
}

export interface StripePayoutsOptions {
  addToast: (message: string, kind?: "success" | "error") => void;
  /** Gates the on-mount status load + stripe_return detection (auth). */
  enabled?: boolean;
  /** Page-specific data reload to run after a successful withdrawal. */
  onAfterWithdraw?: () => Promise<unknown> | void;
  /** Optional analytics hooks (provider earnings tracks these). */
  onWithdrawStart?: (method: WithdrawMethod) => void;
  onWithdrawSuccess?: (method: WithdrawMethod) => void;
  onWithdrawError?: () => void;
}
