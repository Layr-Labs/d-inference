import { query } from "@/lib/db";

export function observationDays(value?: string): number {
  return value === "1" ? 1 : 7;
}

const census = `WITH recent AS (
 SELECT s.*,m.assurance FROM darkbloom_machine_sessions s
 JOIN darkbloom_machines m ON m.id=s.machine_id
 WHERE s.last_seen >= NOW()-$1::int*INTERVAL '1 day'
), latest AS (
 SELECT DISTINCT ON (machine_id) * FROM recent ORDER BY machine_id,last_seen DESC,session_id
)`;

export async function appAttestCensus(days: number) {
  const [row] = await query<{
    machines: string; accounts: string; sessions: string; provisional: string;
    hardware_verified: string; key_bound: string; macos27: string; os_unknown: string;
    protocol_capable: string; shadow_off: string; online: string; ever_macos27: string; verified_machines: string; credentials: string; refused: string; historical_sessions: string;
  }>(`${census} SELECT COUNT(*) AS machines,
    (SELECT COUNT(DISTINCT NULLIF(account_id,'')) FROM recent) AS accounts,
    (SELECT COUNT(*) FROM recent) AS sessions,
    COUNT(*) FILTER(WHERE assurance='provisional') AS provisional,
    COUNT(*) FILTER(WHERE assurance='hardware_verified') AS hardware_verified,
    COUNT(*) FILTER(WHERE assurance='key_bound') AS key_bound,
    COUNT(*) FILTER(WHERE (observation->>'os_major')::int>=27) AS macos27,
    COUNT(*) FILTER(WHERE COALESCE((observation->>'os_major')::int,0)=0) AS os_unknown,
    COUNT(*) FILTER(WHERE (observation->>'protocol')::int IN (1,2)) AS protocol_capable,
    COUNT(*) FILTER(WHERE observation->>'source'='live_registration' AND NOT (observation->>'shadow_enabled')::boolean) AS shadow_off,
    COUNT(*) FILTER(WHERE disconnected_at IS NULL AND last_seen>NOW()-INTERVAL '90 seconds') AS online
    ,COUNT(*) FILTER(WHERE EXISTS(SELECT 1 FROM darkbloom_machine_observations o JOIN darkbloom_machine_sessions s ON s.session_id=o.session_id WHERE s.machine_id=latest.machine_id AND (o.observation->>'os_major')::int>=27)) AS ever_macos27
    ,(SELECT COUNT(DISTINCT s.machine_id) FROM app_attest_evidence e JOIN darkbloom_machine_sessions s ON s.session_id=e.session_id WHERE e.action='assertion' AND e.outcome='verified' AND e.received_at>=NOW()-$1::int*INTERVAL '1 day') AS verified_machines
    ,(SELECT COUNT(DISTINCT key_id) FROM app_attest_evidence WHERE outcome='verified' AND received_at>=NOW()-$1::int*INTERVAL '1 day') AS credentials
    ,(SELECT COALESCE(SUM((observation->>'shadow_dropped')::bigint),0) FROM recent) AS refused
    ,(SELECT COUNT(*) FROM recent WHERE observation->>'source'='historical_registration') AS historical_sessions
    FROM latest`, [days]);
  return row;
}

export async function appAttestMachines(days: number) {
  return query<{
    machine_id: string; assurance: string; account_id: string; last_seen: string;
    os_version: string; os_build: string; version: string; chip: string;
    evaluated_at: string; sessions: string; first_macos27: string | null; last_assertion: string | null;
  }>(`${census} SELECT l.machine_id,l.assurance,l.account_id,l.last_seen,NOW() AS evaluated_at,
    l.observation->>'os_version' AS os_version,l.observation->>'os_build' AS os_build,
    l.observation->>'version' AS version,l.observation->>'chip' AS chip,
    (SELECT COUNT(*) FROM recent r WHERE r.machine_id=l.machine_id) AS sessions,
    (SELECT MIN(o.observed_at) FROM darkbloom_machine_observations o
      JOIN darkbloom_machine_sessions s ON s.session_id=o.session_id
      WHERE s.machine_id=l.machine_id AND (o.observation->>'os_major')::int>=27) AS first_macos27,
    (SELECT MAX(e.received_at) FROM app_attest_evidence e JOIN darkbloom_machine_sessions s ON s.session_id=e.session_id
      WHERE s.machine_id=l.machine_id AND e.action='assertion' AND e.outcome='verified') AS last_assertion
    FROM latest l ORDER BY l.last_seen DESC,l.machine_id LIMIT 200`, [days]);
}

export async function appAttestStages(days: number) {
  return query<{stage: string; outcome: string; events: string; machines: string; p95_ms: number | null}>(`
    SELECT e.stage,e.outcome,COUNT(*) AS events,COUNT(DISTINCT s.machine_id) AS machines,
    percentile_cont(0.95) WITHIN GROUP(ORDER BY (e.fields->>'duration_ms')::float) AS p95_ms
    FROM app_attest_shadow_events e LEFT JOIN darkbloom_machine_sessions s ON s.session_id=e.session_id
    WHERE e.observed_at>=NOW()-$1::int*INTERVAL '1 day' GROUP BY e.stage,e.outcome ORDER BY e.stage,events DESC`, [days]);
}

export async function appAttestArchiveHealth(days: number) {
  return query<{kind: string; outcome: string; count: string}>(`
    SELECT 'proof' AS kind,outcome,COUNT(*) AS count FROM app_attest_evidence
    WHERE received_at>=NOW()-$1::int*INTERVAL '1 day' GROUP BY outcome
    UNION ALL SELECT 'receipt',outcome,COUNT(*) FROM app_attest_receipts
    WHERE received_at>=NOW()-$1::int*INTERVAL '1 day' GROUP BY outcome
    UNION ALL SELECT 'receipt job','awaiting renewal',COUNT(*) FROM app_attest_receipt_jobs
    WHERE next_at<=NOW()`, [days]);
}

export async function appAttestMachineHistory(id: string, offset: number) {
  return query<{id: string; received_at: string; action: string; outcome: string; key_id: string; account_id: string; session_id: string; sha256: string}>(`
    SELECT e.id,e.received_at,e.action,e.outcome,e.key_id,s.account_id,e.session_id,e.sha256
    FROM app_attest_evidence e JOIN darkbloom_machine_sessions s ON s.session_id=e.session_id
    WHERE s.machine_id=$1 ORDER BY e.received_at DESC,e.id LIMIT 100 OFFSET $2`, [id,offset]);
}
