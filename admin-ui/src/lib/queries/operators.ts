import "server-only";
import { query } from "@/lib/db";

export interface OperatorRow {
  email: string;
  account_id: string;
  machines: number;
  online: number;
  ram_gb: string; // sum of memory_gb across the owner's machines
  reqs: string; // sum of lifetime_requests_served (BIGINT → string)
  models: string[]; // distinct model ids across the owner's machines
  balance_micro_usd: string;
  last_seen: string; // most recent heartbeat across the owner's machines
}

// One row per owner (account → email): machines deduped by serial, then grouped
// by account. Only linked machines (account_id <> '') appear — unlinked machines
// have no owner and live only on the Machines page.
export async function listOperators(limit = 5000): Promise<OperatorRow[]> {
  const rows = await query<
    Omit<OperatorRow, "machines" | "online"> & { machines: string; online: string }
  >(
    `WITH latest AS (
       SELECT DISTINCT ON (serial_number) account_id, serial_number, last_seen, hardware, models,
              lifetime_requests_served
         FROM providers
        WHERE serial_number <> '' AND account_id <> ''
        ORDER BY serial_number, last_seen DESC
     ),
     owner_models AS (
       SELECT l.account_id, array_agg(DISTINCT e->>'id') AS models
         FROM latest l, jsonb_array_elements(l.models) e
        GROUP BY l.account_id
     )
     SELECT u.email,
            l.account_id,
            count(*)                                                              AS machines,
            count(*) FILTER (WHERE now() - l.last_seen < interval '90 seconds')   AS online,
            sum(COALESCE((l.hardware->>'memory_gb')::numeric, 0))::bigint         AS ram_gb,
            sum(l.lifetime_requests_served)                                       AS reqs,
            COALESCE(om.models, '{}')                                             AS models,
            COALESCE(b.balance_micro_usd, 0)                                      AS balance_micro_usd,
            max(l.last_seen)                                                      AS last_seen
       FROM latest l
       JOIN users u ON u.account_id = l.account_id
       LEFT JOIN owner_models om ON om.account_id = l.account_id
       LEFT JOIN balances b ON b.account_id = l.account_id
      GROUP BY l.account_id, u.email, om.models, b.balance_micro_usd
      ORDER BY machines DESC, reqs DESC
      LIMIT $1`,
    [limit],
  );
  return rows.map((r) => ({
    ...r,
    machines: Number(r.machines),
    online: Number(r.online),
    models: r.models ?? [],
  }));
}
