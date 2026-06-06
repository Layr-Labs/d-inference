import "server-only";
import { query } from "@/lib/db";

export interface TableCount {
  table: string;
  estRows: number;
}

// Catalog-only estimated row counts — instant, and immune to replica
// recovery-conflicts (no scan of the data tables).
export async function getTableCounts(): Promise<TableCount[]> {
  const rows = await query<{ table: string; est_rows: string }>(
    // reltuples is -1 for a never-analyzed relation (PG14+); clamp to 0 so a
    // freshly-created table doesn't render "-1" until autovacuum/ANALYZE runs.
    `SELECT c.relname AS table, GREATEST(c.reltuples, 0)::bigint AS est_rows
       FROM pg_class c
       JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relkind = 'r'
      ORDER BY c.relname`,
  );
  return rows.map((r) => ({ table: r.table, estRows: Number(r.est_rows) }));
}

export interface HeadlineStats {
  users: number;
  machines: number;
  onlineMachines: number;
}

// Exact headline numbers. Kept cheap: distinct machines + online use the
// providers table only, bounded by statement_timeout.
export async function getHeadlineStats(): Promise<HeadlineStats> {
  const [users] = await query<{ n: string }>(`SELECT count(*) AS n FROM users`);
  const [machines] = await query<{ total: string; online: string }>(
    `SELECT count(DISTINCT serial_number) FILTER (WHERE serial_number <> '') AS total,
            count(DISTINCT serial_number) FILTER (WHERE serial_number <> '' AND now() - last_seen < interval '90 seconds') AS online
       FROM providers`,
  );
  return {
    users: Number(users?.n ?? 0),
    machines: Number(machines?.total ?? 0),
    onlineMachines: Number(machines?.online ?? 0),
  };
}
