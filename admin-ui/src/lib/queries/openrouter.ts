import "server-only";
import { query } from "@/lib/db";

export interface OpenRouterAccountRow {
  account_id: string;
  email: string;
  role: string;
  balance_micro_usd: string;
  withdrawable_micro_usd: string;
  key_count: number;
  ledger_count: number;
  usage_requests: number;
  usage_cost_micro: string;
  created_at: string;
}

// All @openrouter.ai accounts with balance, key count, ledger volume and
// attributable usage. role='service' accounts are the integration channels
// (elevated rate limits, billed at platform price — no markup); the rest are
// org members. Scoped by email rather than role='service' on purpose: other
// internal accounts (e.g. the owner) also carry the service role.
export async function listOpenRouterAccounts(): Promise<OpenRouterAccountRow[]> {
  const rows = await query<
    Omit<OpenRouterAccountRow, "key_count" | "ledger_count" | "usage_requests"> & {
      key_count: string;
      ledger_count: string;
      usage_requests: string;
    }
  >(
    `WITH accts AS (
       SELECT account_id, email, role, created_at
         FROM users
        WHERE email ILIKE $1
     )
     SELECT a.account_id,
            a.email,
            a.role,
            a.created_at,
            COALESCE(b.balance_micro_usd, 0)      AS balance_micro_usd,
            COALESCE(b.withdrawable_micro_usd, 0) AS withdrawable_micro_usd,
            (SELECT count(*) FROM api_keys k WHERE k.owner_account_id = a.account_id)     AS key_count,
            (SELECT count(*) FROM ledger_entries l WHERE l.account_id = a.account_id)     AS ledger_count,
            COALESCE((SELECT count(*) FROM usage u
                        JOIN api_keys k ON k.key_hash = u.consumer_key_hash
                       WHERE k.owner_account_id = a.account_id), 0)                       AS usage_requests,
            COALESCE((SELECT sum(u.cost_micro_usd) FROM usage u
                        JOIN api_keys k ON k.key_hash = u.consumer_key_hash
                       WHERE k.owner_account_id = a.account_id), 0)                       AS usage_cost_micro
       FROM accts a
       LEFT JOIN balances b ON b.account_id = a.account_id
      ORDER BY (a.role = 'service') DESC, a.email`,
    ["%@openrouter.ai%"],
  );
  return rows.map((r) => ({
    ...r,
    key_count: Number(r.key_count),
    ledger_count: Number(r.ledger_count),
    usage_requests: Number(r.usage_requests),
  }));
}
