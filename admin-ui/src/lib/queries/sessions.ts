import "server-only";
import { query } from "@/lib/db";

// Rows come from provider_sessions, written by the coordinator on
// connect/heartbeat/disconnect. Table only exists after a coordinator deploy;
// callers should tolerate a 42P01 (undefined_table) via isUndefinedTable().

export interface SessionRow {
  id: string;
  session_id: string;
  serial_number: string;
  email: string | null;
  connected_at: string;
  last_seen: string;
  disconnected_at: string | null;
  disconnect_reason: string;
  duration_seconds: string; // EXTRACT(EPOCH ...) → bigint as string
}

export interface UptimeOverview {
  totalSessions: number;
  openSessions: number; // currently connected
  sessions24h: number;
  recent: SessionRow[];
}

const RECENT_SESSION_SQL = `
  SELECT ps.id,
         ps.session_id,
         ps.serial_number,
         u.email,
         ps.connected_at,
         ps.last_seen,
         ps.disconnected_at,
         ps.disconnect_reason,
         EXTRACT(EPOCH FROM (COALESCE(ps.disconnected_at, now()) - ps.connected_at))::bigint
           AS duration_seconds
    FROM provider_sessions ps
    LEFT JOIN users u ON u.account_id = ps.account_id`;

export async function getUptimeOverview(limit = 200): Promise<UptimeOverview> {
  const [counts] = await query<{ total: string; open: string; last24: string }>(
    `SELECT count(*)                                                       AS total,
            count(*) FILTER (WHERE disconnected_at IS NULL)                AS open,
            count(*) FILTER (WHERE connected_at > now() - interval '24 hours') AS last24
       FROM provider_sessions`,
  );
  // ORDER BY id DESC = PK index (monotonic ≈ recency); no created_at index here.
  const recent = await query<SessionRow>(
    `${RECENT_SESSION_SQL} ORDER BY ps.id DESC LIMIT $1`,
    [limit],
  );
  return {
    totalSessions: Number(counts?.total ?? 0),
    openSessions: Number(counts?.open ?? 0),
    sessions24h: Number(counts?.last24 ?? 0),
    recent,
  };
}

// Sessions for one machine (by serial), newest first — for the machine drill-down.
// ORDER BY connected_at DESC is fully served by the (serial_number, connected_at DESC)
// index once the serial filter is applied.
export async function getMachineSessions(serial: string, limit = 50): Promise<SessionRow[]> {
  return query<SessionRow>(
    `${RECENT_SESSION_SQL} WHERE ps.serial_number = $1 ORDER BY ps.connected_at DESC LIMIT $2`,
    [serial, limit],
  );
}
