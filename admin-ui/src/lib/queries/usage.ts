import "server-only";
import { query } from "@/lib/db";

export interface UsageRow {
  id: string;
  created_at: string;
  model: string;
  prompt_tokens: string;
  completion_tokens: string;
  cost_micro_usd: string;
  email: string | null;
  provider_id: string;
  request_id: string;
}

// Most recent usage records, joined to the owner's email via the consumer key.
// usage.consumer_key_hash -> api_keys.key_hash -> users.account_id -> email.
// All joins are LEFT (key may be deleted / unlinked), so email can be null.
// Ordered by created_at (idx_usage_created is created_at DESC).
//
// NEVER select consumer_key_hash here — it is a credential hash.
export async function listUsage(limit = 200, offset = 0): Promise<UsageRow[]> {
  return query<UsageRow>(
    `SELECT us.id,
            us.created_at,
            us.model,
            us.prompt_tokens,
            us.completion_tokens,
            us.cost_micro_usd,
            u.email,
            us.provider_id,
            us.request_id
       FROM usage us
       LEFT JOIN api_keys k ON k.key_hash = us.consumer_key_hash
       LEFT JOIN users u ON u.account_id = k.owner_account_id
                        AND k.owner_account_id <> ''
      ORDER BY us.created_at DESC
      LIMIT $1 OFFSET $2`,
    [limit, offset],
  );
}

export async function countUsage(): Promise<number> {
  const [r] = await query<{ n: string }>(`SELECT count(*) AS n FROM usage`);
  return Number(r?.n ?? 0);
}
