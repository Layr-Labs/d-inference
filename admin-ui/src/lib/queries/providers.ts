import "server-only";
import { query } from "@/lib/db";

export interface MachineRow {
  serial_number: string;
  session_id: string;
  account_id: string;
  email: string | null;
  chip_name: string | null;
  memory_gb: number | null;
  gpu_cores: number | null;
  machine_model: string | null;
  version: string;
  trust_level: string;
  attested: boolean;
  mda_verified: boolean;
  model_ids: string[];
  last_seen: string;
  registered_at: string;
  lifetime_requests_served: string;
  lifetime_tokens_generated: string;
}

// One row per physical machine (deduped by serial_number, keeping the most
// recent session row), joined to the owner's email. Ordered by recency.
//
// NOTE on uptime: the schema only persists `last_seen` (a 30s-throttled
// heartbeat). There is no connect/disconnect history, so "online" is a
// heuristic (last_seen within ~90s) and there is no uptime duration yet.
// The provider_sessions capture (separate work) will add real history.
export async function listMachines(limit = 200, offset = 0): Promise<MachineRow[]> {
  const rows = await query<
    Omit<MachineRow, "memory_gb" | "gpu_cores"> & {
      memory_gb: string | null;
      gpu_cores: string | null;
    }
  >(
    `WITH latest AS (
       SELECT DISTINCT ON (serial_number) *
         FROM providers
        WHERE serial_number <> ''
        ORDER BY serial_number, last_seen DESC
     )
     SELECT l.serial_number,
            l.id                         AS session_id,
            l.account_id,
            u.email,
            l.hardware->>'chip_name'     AS chip_name,
            l.hardware->>'memory_gb'     AS memory_gb,
            l.hardware->>'gpu_cores'     AS gpu_cores,
            l.hardware->>'machine_model' AS machine_model,
            l.version,
            l.trust_level,
            l.attested,
            l.mda_verified,
            COALESCE(
              (SELECT array_agg(e->>'id') FROM jsonb_array_elements(l.models) e),
              '{}'
            )                            AS model_ids,
            l.last_seen,
            l.registered_at,
            l.lifetime_requests_served,
            l.lifetime_tokens_generated
       FROM latest l
       LEFT JOIN users u ON u.account_id = l.account_id
      ORDER BY l.last_seen DESC
      LIMIT $1 OFFSET $2`,
    [limit, offset],
  );
  return rows.map((r) => ({
    ...r,
    memory_gb: r.memory_gb === null ? null : Number(r.memory_gb),
    gpu_cores: r.gpu_cores === null ? null : Number(r.gpu_cores),
  }));
}

export async function countMachines(): Promise<number> {
  const [r] = await query<{ n: string }>(
    `SELECT count(DISTINCT serial_number) AS n FROM providers WHERE serial_number <> ''`,
  );
  return Number(r?.n ?? 0);
}
