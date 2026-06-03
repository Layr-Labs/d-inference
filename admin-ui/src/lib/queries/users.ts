import "server-only";
import { query } from "@/lib/db";

export interface UserRow {
  account_id: string;
  privy_user_id: string;
  email: string;
  role: string;
  platform_fee_percent: number | null;
  balance_micro_usd: string | null;
  machine_count: number;
  created_at: string;
}

// Users joined to their balance and machine count. Paginated by created_at.
export async function listUsers(limit = 100, offset = 0): Promise<UserRow[]> {
  const rows = await query<UserRow & { machine_count: string }>(
    `SELECT u.account_id,
            u.privy_user_id,
            u.email,
            u.role,
            u.platform_fee_percent,
            b.balance_micro_usd,
            COALESCE(m.cnt, 0) AS machine_count,
            u.created_at
       FROM users u
       LEFT JOIN balances b ON b.account_id = u.account_id
       LEFT JOIN (
         SELECT account_id, count(DISTINCT serial_number) AS cnt
           FROM providers
          WHERE account_id <> '' AND serial_number <> ''
          GROUP BY account_id
       ) m ON m.account_id = u.account_id
      ORDER BY u.created_at DESC
      LIMIT $1 OFFSET $2`,
    [limit, offset],
  );
  return rows.map((r) => ({ ...r, machine_count: Number(r.machine_count) }));
}

export async function countUsers(): Promise<number> {
  const [r] = await query<{ n: string }>(`SELECT count(*) AS n FROM users`);
  return Number(r?.n ?? 0);
}
