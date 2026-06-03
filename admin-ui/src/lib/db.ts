import "server-only";
import { Pool, type QueryResultRow } from "pg";

// Single server-side connection pool to the READ-ONLY replica.
// Never import this from a client component — the connection string is secret.
//
// Safety layers:
//  - The `readonly` role has SELECT-only grants.
//  - The replica is physically read-only (transaction_read_only=on).
//  - statement_timeout caps any query so a replica recovery-conflict can't hang.

declare global {
  var __adminPool: Pool | undefined;
}

function makePool(): Pool {
  const raw = process.env.ADMIN_DB_URL;
  if (!raw) {
    throw new Error(
      "ADMIN_DB_URL is not set — point it at the read-only replica (readonly role).",
    );
  }
  // node-postgres treats `sslmode=require` in the URL as `verify-full` (full cert
  // verification). RDS uses a CA not in the default trust store, so strip sslmode
  // and control TLS explicitly via the `ssl` option below.
  let connectionString = raw;
  try {
    const u = new URL(raw);
    u.searchParams.delete("sslmode");
    u.searchParams.delete("ssl");
    connectionString = u.toString();
  } catch {
    /* not a parseable URL — pass through unchanged */
  }

  const noVerify = process.env.ADMIN_DB_SSL_NO_VERIFY === "true";
  return new Pool({
    connectionString,
    max: 4,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 10_000,
    // Hard caps — replica WAL-replay conflicts otherwise stall reads.
    statement_timeout: 15_000,
    query_timeout: 20_000,
    application_name: "admin-ui",
    // noVerify: encrypt without cert verification (internal tool). Otherwise
    // require a CA the system trusts (install the AWS RDS global bundle).
    ssl: noVerify ? { rejectUnauthorized: false } : true,
  });
}

export const pool: Pool = globalThis.__adminPool ?? makePool();
if (process.env.NODE_ENV !== "production") globalThis.__adminPool = pool;

/**
 * Run a parameterized SELECT. Always use $1/$2 params — never interpolate.
 * Retries once on a transient hot-standby WAL-replay conflict (SQLSTATE 40001),
 * which the replica raises when a long read collides with replication. Errors
 * are logged server-side and rethrown so the route's error boundary renders.
 */
export async function query<T extends QueryResultRow = QueryResultRow>(
  text: string,
  params: unknown[] = [],
): Promise<T[]> {
  for (let attempt = 0; ; attempt++) {
    try {
      const res = await pool.query<T>(text, params);
      return res.rows;
    } catch (err) {
      const code = (err as { code?: string }).code;
      if (code === "40001" && attempt < 1) {
        await new Promise((r) => setTimeout(r, 250));
        continue;
      }
      console.error(
        "[admin-ui] query failed:",
        err instanceof Error ? err.message : err,
      );
      throw err;
    }
  }
}

/**
 * True if the error is Postgres "undefined_table" (42P01) — used by features
 * whose tables only exist after a coordinator deploy (e.g. provider_sessions),
 * so the page can show an "awaiting deploy" notice instead of an error.
 */
export function isUndefinedTable(err: unknown): boolean {
  return (err as { code?: string })?.code === "42P01";
}

/** Convenience for COUNT(*)-style single scalar queries. */
export async function scalar<T = string>(
  text: string,
  params: unknown[] = [],
): Promise<T | null> {
  const rows = await query(text, params);
  if (rows.length === 0) return null;
  const first = rows[0];
  const keys = Object.keys(first);
  return keys.length ? (first[keys[0]] as T) : null;
}
