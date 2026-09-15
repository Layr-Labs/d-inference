import { query } from "@/lib/db";

// One current observation per machine. A success on an older connection never
// makes a replacement connection ready. Stored prospective verdicts expire.
const readiness = `WITH latest AS (
 SELECT DISTINCT ON (machine_id) machine_id,session_id,disconnected_at,last_seen,observation
 FROM darkbloom_machine_sessions WHERE last_seen>=NOW()-$1::int*INTERVAL '1 day'
 ORDER BY machine_id,(disconnected_at IS NULL AND last_seen>NOW()-INTERVAL '90 seconds') DESC,last_seen DESC,session_id
), observed AS (
 SELECT l.*,p.fields,p.outcome,p.id AS policy_id,
 EXISTS(SELECT 1 FROM app_attest_key_revocations r WHERE r.key_id=p.fields->>'credential_id') AS credential_revoked
 FROM latest l LEFT JOIN LATERAL (
 SELECT id,outcome,fields FROM app_attest_shadow_events
 WHERE session_id=l.session_id AND stage='prospective_policy'
 ORDER BY observed_at DESC,id DESC LIMIT 1) p ON TRUE
), evaluated AS (
 SELECT observed.*,CASE
 WHEN disconnected_at IS NOT NULL OR last_seen<NOW()-INTERVAL '90 seconds' THEN 'offline'
 WHEN policy_id IS NULL THEN 'not_evaluated'
 WHEN credential_revoked THEN 'ineligible'
 WHEN outcome='eligible' AND (fields->>'valid_until')::timestamptz<=NOW() THEN 'stale'
 ELSE outcome END AS readiness
 FROM observed
)`;

export async function appAttestReadinessCohorts(days: number) {
  return query<{ readiness: string; version: string; machines: string }>(`${readiness}
    SELECT readiness,COALESCE(observation->>'version','unknown') AS version,COUNT(*) AS machines
    FROM evaluated GROUP BY readiness,version ORDER BY readiness,version`, [days]);
}

export async function appAttestReadinessReasons(days: number) {
  return query<{ reason: string; machines: string }>(`${readiness}
    SELECT reason,COUNT(DISTINCT machine_id) AS machines FROM evaluated
    CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(fields->'reasons','[]'::jsonb)
      || CASE WHEN credential_revoked THEN '["credential_revoked"]'::jsonb ELSE '[]'::jsonb END) reason
    WHERE readiness IN ('unknown','ineligible') GROUP BY reason ORDER BY machines DESC,reason`, [days]);
}
