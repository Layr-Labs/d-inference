import "server-only";
import { query } from "@/lib/db";

// API key metadata only. The credential lives in api_keys.key_hash and is
// NEVER selected or rendered — only safe metadata is exposed here.
export interface ApiKeyRow {
  id: string;
  name: string;
  raw_prefix: string;
  owner_account_id: string;
  email: string | null;
  active: boolean;
  limit_micro_usd: string | null;
  rpm_limit: string | null;
  last_used_at: string | null;
  created_at: string;
}

// Most recent 200 API keys, newest first, joined to the owner's email.
// owner_account_id joins to users.account_id; many rows have account_id=''
// (unlinked), so email comes back NULL.
export async function listApiKeys(limit = 200, offset = 0): Promise<ApiKeyRow[]> {
  return query<ApiKeyRow>(
    `SELECT k.id,
            k.name,
            k.raw_prefix,
            k.owner_account_id,
            u.email,
            k.active,
            k.limit_micro_usd,
            k.rpm_limit,
            k.last_used_at,
            k.created_at
       FROM api_keys k
       LEFT JOIN users u ON u.account_id = k.owner_account_id
      ORDER BY k.created_at DESC
      LIMIT $1 OFFSET $2`,
    [limit, offset],
  );
}

export async function countApiKeys(): Promise<number> {
  const [r] = await query<{ n: string }>(`SELECT count(*) AS n FROM api_keys`);
  return Number(r?.n ?? 0);
}
