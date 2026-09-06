// Wire types for GET /api/me/earnings (coordinator handleAccountEarnings).

export interface Earning {
  id: number;
  provider_id: string;
  provider_key: string;
  job_id: string;
  model: string;
  amount_micro_usd: number;
  prompt_tokens: number;
  completion_tokens: number;
  created_at: string;
}

export interface EarningsResponse {
  account_id: string;
  earnings: Earning[];
  total_micro_usd: number;
  total_usd: string;
  count: number;
  recent_count: number;
  history_limit: number;
  available_balance_micro_usd: number;
  available_balance_usd: string;
  withdrawable_balance_micro_usd: number;
  withdrawable_balance_usd: string;
}
