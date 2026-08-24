// Public API client barrel. Preserves the `@/lib/api` import path while the
// implementation is split into per-domain modules + lib/chat (proposal F1).
// All requests go through the Next.js /api/* proxy routes to avoid CORS; the
// coordinator URL is resolved server-side, never from client input.

export * from "./types";

export { ApiError, apiErrorFromBody, parseApiErrorBody } from "./errors";
export { fetchModels } from "./models";
export { fetchEarningsMarket, parseEarningsMarket } from "./earnings-market";
export { fetchPricing } from "./pricing";
export { healthCheck } from "./health";
export { redeemInviteCode } from "./invite";
export {
  fetchBalance,
  fetchUsage,
  createStripeCheckout,
  fetchStripeStatus,
  startStripeOnboarding,
  createStripeDashboardLink,
  withdrawStripe,
  fetchStripeWithdrawals,
  unlinkStripeAccount,
  computeStripeFeeUsd,
} from "./billing";
export {
  listApiKeys,
  createApiKey,
  updateApiKey,
  deleteApiKey,
  rotateApiKey,
} from "./keys";
export { deleteProvider } from "./providers";
export { streamChat } from "../chat/stream";
