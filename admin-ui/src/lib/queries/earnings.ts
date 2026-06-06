import "server-only";
import { query } from "@/lib/db";

export interface TopEarnerRow {
  key: string;
  email: string | null;
  total_micro_usd: string;
  total_count: string;
  total_prompt_tokens: string;
  total_completion_tokens: string;
  updated_at: string;
}

// Top earners from the materialized earnings_summary table, restricted to
// account-keyed rows (key = account_id) so the LEFT JOIN to users resolves an
// email. Ordered by lifetime earnings. BIGINT columns stay strings.
export async function listTopEarners(limit = 100): Promise<TopEarnerRow[]> {
  return query<TopEarnerRow>(
    `SELECT e.key,
            u.email,
            e.total_micro_usd,
            e.total_count,
            e.total_prompt_tokens,
            e.total_completion_tokens,
            e.updated_at
       FROM earnings_summary e
       LEFT JOIN users u ON u.account_id = e.key
      WHERE e.key_type = 'account'
      ORDER BY e.total_micro_usd DESC
      LIMIT $1`,
    [limit],
  );
}

export interface RecentEarningRow {
  id: string;
  account_id: string;
  email: string | null;
  provider_id: string;
  provider_key: string;
  job_id: string;
  model: string;
  amount_micro_usd: string;
  prompt_tokens: number;
  completion_tokens: number;
  created_at: string;
}

// Most recent per-job earnings, joined to the owning account's email. Ordered
// by the BIGSERIAL id (PK index) as a monotonic recency proxy — there is no
// standalone created_at index on this ~140k-row table. amount_micro_usd is
// BIGINT (string); the token columns are INTEGER (safe as numbers).
export async function listRecentEarnings(limit = 100): Promise<RecentEarningRow[]> {
  return query<RecentEarningRow>(
    `SELECT pe.id,
            pe.account_id,
            u.email,
            pe.provider_id,
            pe.provider_key,
            pe.job_id,
            pe.model,
            pe.amount_micro_usd,
            pe.prompt_tokens,
            pe.completion_tokens,
            pe.created_at
       FROM provider_earnings pe
       LEFT JOIN users u ON u.account_id = pe.account_id
      ORDER BY pe.id DESC
      LIMIT $1`,
    [limit],
  );
}
