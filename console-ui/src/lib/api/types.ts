// Shared API types. Split out of the old monolithic lib/api.ts so the per-domain
// client modules (and consumers) import them from one place (proposal F1).

export interface ModelPricing {
  prompt: string;
  completion: string;
  image?: string;
  request?: string;
  input_cache_read?: string;
}

export interface Model {
  id: string;
  object: string;
  owned_by?: string;
  size_bytes?: number;
  model_type?: string;
  quantization?: string;
  provider_count?: number;
  attested?: boolean;
  trust_level?: string;
  display_name?: string;
  size_gb?: number;
  min_ram_gb?: number;
  max_context_length?: number;
  max_output_length?: number;
  architecture?: string;
  family?: string;
  capabilities?: string[];
  // OpenRouter provider schema fields (from the enriched /v1/models endpoint).
  name?: string;
  hugging_face_id?: string;
  created?: number;
  description?: string;
  context_length?: number;
  pricing?: ModelPricing;
  input_modalities?: string[];
  output_modalities?: string[];
  supported_features?: string[];
  supported_sampling_parameters?: string[];
}

export interface BalanceResponse {
  balance_micro_usd: number;
  balance_usd: number;
  withdrawable_micro_usd: number;
  withdrawable_usd: number;
}

export interface UsageEntry {
  request_id: string;
  model: string;
  prompt_tokens: number;
  completion_tokens: number;
  cost_micro_usd: number;
  timestamp: string;
}

/**
 * A content part in the OpenAI/OpenRouter multimodal format. Either a text
 * part or an image part. The image `url` is a base64 `data:` URI — our
 * provider is end-to-end-encrypted and rejects remote http(s)/file URLs
 * (the image must ride inside the encrypted prompt). Mirrors the provider's
 * `OpenAIContentPart`.
 */
export type ChatContentPart =
  | { type: "text"; text: string }
  | { type: "image_url"; image_url: { url: string } };

export interface ChatMessage {
  role: "user" | "assistant" | "system";
  // `string` for text-only turns (unchanged wire shape); a parts array when
  // the turn carries images, matching the standard OpenAI/OpenRouter
  // `image_url` content-part format.
  content: string | ChatContentPart[];
}

export interface TrustMetadata {
  attested: boolean;
  trustLevel: "none" | "hardware";
  secureEnclave: boolean;
  mdaVerified: boolean;
  providerChip: string;
  providerSerial: string;
  providerModel: string;
  // Attestation receipt fields (per-request SE signature)
  responseHash?: string;
  seSignature?: string;
  sePublicKey?: string;
  deviceSerial?: string;
}

export interface StreamMetrics {
  tps: number;
  ttft: number;
  tokenCount: number;
}

export interface StreamCallbacks {
  onToken: (token: string) => void;
  onThinking: (token: string) => void;
  onMetrics: (metrics: StreamMetrics) => void;
  onDone: (trustMeta: TrustMetadata, metrics: StreamMetrics) => void;
  onError: (error: string) => void;
}

export interface PriceEntry {
  model: string;
  input_price: number;
  output_price: number;
  input_usd: string;
  output_usd: string;
}

export interface PricingResponse {
  prices: PriceEntry[];
}

export interface StripeCheckoutResponse {
  url: string;
  session_id: string;
}

export interface InviteRedeemResponse {
  credited_usd: string;
  balance_usd: string;
}

export interface StripeStatus {
  configured: boolean;
  has_account: boolean;
  stripe_account_id?: string;
  stripe_account_country?: string;
  status: "" | "pending" | "ready" | "restricted" | "rejected";
  destination_type?: "" | "bank" | "card";
  destination_last4?: string;
  instant_eligible?: boolean;
  min_withdraw_micro_usd?: number;
  instant_fee_bps?: number;
  instant_fee_min_usd?: number;
  currently_due?: string[];
}

export interface StripeOnboardResponse {
  url: string;
  stripe_account_id: string;
  status: string;
}

export interface StripeWithdrawResponse {
  status: string;
  withdrawal_id: string;
  transfer_id?: string;
  payout_id?: string;
  amount_usd: string;
  fee_usd: string;
  net_usd: string;
  method: "standard" | "instant";
  eta?: string;
  arrival_unix?: number;
  balance_micro_usd: number;
}

export interface StripeWithdrawal {
  id: string;
  account_id: string;
  stripe_account_id: string;
  transfer_id?: string;
  payout_id?: string;
  amount_micro_usd: number;
  fee_micro_usd: number;
  net_micro_usd: number;
  method: "standard" | "instant";
  status: "pending" | "transferred" | "paid" | "failed";
  failure_reason?: string;
  refunded?: boolean;
  created_at: string;
  updated_at: string;
}

export type KeyResetWindow = "none" | "daily" | "weekly" | "monthly";

export interface ApiKey {
  id: string;
  name: string;
  label: string; // masked, e.g. "sk-db-1a2b...c3d4"
  disabled: boolean;
  limit_usd?: number; // spend cap; omitted if unlimited
  limit_reset: KeyResetWindow;
  usage_usd: number; // spend in the current window
  remaining_usd?: number; // omitted if unlimited
  rpm_limit?: number;
  itpm_limit?: number;
  otpm_limit?: number;
  allowed_models?: string[]; // empty/omitted = all models
  self_route_only?: boolean; // hard ceiling: only routes to the owner's machine, free
  expires_at?: string; // RFC3339 UTC
  created_at: string;
  last_used_at?: string;
}

// Create body. Nullable fields are omitted on create; sending an explicit
// null on update CLEARS the field.
export interface CreateKeyBody {
  name?: string;
  limit_usd?: number | null;
  limit_reset?: KeyResetWindow;
  rpm_limit?: number | null;
  itpm_limit?: number | null;
  otpm_limit?: number | null;
  allowed_models?: string[] | null;
  self_route_only?: boolean;
  expires_at?: string | null; // RFC3339
}

// Update body is any subset of CreateKeyBody plus `disabled`.
export type UpdateKeyBody = CreateKeyBody & { disabled?: boolean };

// Returned by create + rotate: the once-only plaintext secret plus metadata.
export interface CreatedKey {
  key: string; // "sk-db-<secret>" — shown once
  data: ApiKey;
}
