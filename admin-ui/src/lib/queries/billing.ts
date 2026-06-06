import "server-only";
import { query } from "@/lib/db";

export interface BalanceRow {
  account_id: string;
  email: string | null;
  balance_micro_usd: string;
  withdrawable_micro_usd: string;
  updated_at: string;
}

// Largest balances first, joined to the owner's email. account_id may be ''
// (unlinked), in which case there is no matching user and email is null.
export async function listTopBalances(limit = 100): Promise<BalanceRow[]> {
  return query<BalanceRow>(
    `SELECT b.account_id,
            u.email,
            b.balance_micro_usd,
            b.withdrawable_micro_usd,
            b.updated_at
       FROM balances b
       LEFT JOIN users u ON u.account_id = b.account_id
      ORDER BY b.balance_micro_usd DESC
      LIMIT $1`,
    [limit],
  );
}

export interface LedgerRow {
  id: string;
  account_id: string;
  email: string | null;
  entry_type: string;
  amount_micro_usd: string;
  balance_after: string;
  reference: string;
  created_at: string;
}

// Most recent ledger entries fleet-wide. amount_micro_usd is signed (credits
// positive, debits negative). Ordered by the BIGSERIAL id (PK index) as a
// monotonic proxy for recency — there is no standalone created_at index on
// this ~700k-row table, so ORDER BY created_at would full-sort and time out.
export async function listRecentLedger(limit = 100): Promise<LedgerRow[]> {
  return query<LedgerRow>(
    `SELECT l.id,
            l.account_id,
            u.email,
            l.entry_type,
            l.amount_micro_usd,
            l.balance_after,
            l.reference,
            l.created_at
       FROM ledger_entries l
       LEFT JOIN users u ON u.account_id = l.account_id
      ORDER BY l.id DESC
      LIMIT $1`,
    [limit],
  );
}
