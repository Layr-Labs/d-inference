import "server-only";
import { query } from "@/lib/db";

// Hardware blob shape (providers.hardware JSONB). All fields optional — older
// providers may not report every key. Kept loose; rendered via key/value rows.
export interface MachineHardware {
  chip_name?: string | null;
  chip_family?: string | null;
  chip_tier?: string | null;
  cpu_cores?: { total?: number | null } | null;
  gpu_cores?: number | null;
  memory_gb?: number | null;
  memory_bandwidth_gbs?: number | null;
  machine_model?: string | null;
}

export interface MachineDetail {
  serial_number: string;
  id: string;
  account_id: string;
  email: string | null;
  hardware: MachineHardware | null;
  models: Array<Record<string, unknown>>;
  backend: string;
  version: string;
  trust_level: string;
  attested: boolean;
  acme_verified: boolean;
  mda_verified: boolean;
  runtime_verified: boolean;
  se_public_key: string;
  python_hash: string;
  runtime_hash: string;
  last_challenge_verified: string | null;
  failed_challenges: number;
  registered_at: string;
  last_seen: string;
  lifetime_requests_served: string;
  lifetime_tokens_generated: string;
  last_session_requests_served: string;
  last_session_tokens_generated: string;
}

// The latest session row for one physical machine (deduped by serial_number,
// keeping the most recent last_seen), joined to the owner's email.
// hardware/models are returned as parsed JSONB objects/arrays by pg.
//
// NEVER select credential hashes here. python_hash / runtime_hash are runtime
// integrity digests (safe public attestation metadata), not credentials.
export async function getMachineBySerial(serial: string): Promise<MachineDetail | null> {
  const rows = await query<
    Omit<MachineDetail, "failed_challenges"> & { failed_challenges: number | string }
  >(
    `SELECT DISTINCT ON (serial_number)
            serial_number,
            id,
            account_id,
            (SELECT email FROM users u WHERE u.account_id = p.account_id) AS email,
            hardware,
            models,
            backend,
            version,
            trust_level,
            attested,
            acme_verified,
            mda_verified,
            runtime_verified,
            se_public_key,
            python_hash,
            runtime_hash,
            last_challenge_verified,
            failed_challenges,
            registered_at,
            last_seen,
            lifetime_requests_served,
            lifetime_tokens_generated,
            last_session_requests_served,
            last_session_tokens_generated
       FROM providers p
      WHERE serial_number = $1
      ORDER BY serial_number, last_seen DESC
      LIMIT 1`,
    [serial],
  );
  const r = rows[0];
  if (!r) return null;
  return {
    ...r,
    email: r.email && r.email !== "" ? r.email : null,
    hardware: (r.hardware as MachineHardware | null) ?? null,
    models: Array.isArray(r.models) ? (r.models as Array<Record<string, unknown>>) : [],
    failed_challenges: Number(r.failed_challenges),
  };
}

export interface MachineReputation {
  total_jobs: number;
  successful_jobs: number;
  failed_jobs: number;
  avg_response_time_ms: string;
  challenges_passed: number;
  challenges_failed: number;
}

// Persisted reputation counters for one provider session (provider_reputation
// is keyed by providers.id). Returns null if no reputation row exists yet.
export async function getMachineReputation(
  sessionId: string,
): Promise<MachineReputation | null> {
  const rows = await query<
    Omit<MachineReputation, "total_jobs" | "successful_jobs" | "failed_jobs" | "challenges_passed" | "challenges_failed"> & {
      total_jobs: number | string;
      successful_jobs: number | string;
      failed_jobs: number | string;
      challenges_passed: number | string;
      challenges_failed: number | string;
    }
  >(
    `SELECT total_jobs,
            successful_jobs,
            failed_jobs,
            avg_response_time_ms,
            challenges_passed,
            challenges_failed
       FROM provider_reputation
      WHERE provider_id = $1
      LIMIT 1`,
    [sessionId],
  );
  const r = rows[0];
  if (!r) return null;
  return {
    total_jobs: Number(r.total_jobs),
    successful_jobs: Number(r.successful_jobs),
    failed_jobs: Number(r.failed_jobs),
    avg_response_time_ms: String(r.avg_response_time_ms),
    challenges_passed: Number(r.challenges_passed),
    challenges_failed: Number(r.challenges_failed),
  };
}

export interface ProviderUsageRow {
  id: string;
  created_at: string;
  model: string;
  prompt_tokens: string;
  completion_tokens: string;
  cost_micro_usd: string;
}

// Recent usage records served by one provider session (provider_id = the
// latest session row's id). Ordered by created_at (idx_usage_provider covers
// provider_id, created_at DESC).
//
// NEVER select consumer_key_hash here — it is a credential hash.
export async function getRecentUsageForProvider(
  sessionId: string,
  limit = 20,
): Promise<ProviderUsageRow[]> {
  return query<ProviderUsageRow>(
    `SELECT id,
            created_at,
            model,
            prompt_tokens,
            completion_tokens,
            cost_micro_usd
       FROM usage
      WHERE provider_id = $1
      ORDER BY created_at DESC
      LIMIT $2`,
    [sessionId, limit],
  );
}
