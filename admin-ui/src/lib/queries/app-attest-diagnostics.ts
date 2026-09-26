import { query } from "@/lib/db";
import type { BreakdownRow, DeathDayRow } from "@/lib/app-attest-diagnostics";

// Failure-mode diagnostics for macOS 27+ machines. Every query is bounded by
// the indexed observed_at/received_at/requested_at window ($1 days) and joins
// sessions by primary key. Diagnostic JSON fields are untrusted, already
// validated by the coordinator, and absent on old rows: every expression
// tolerates a missing key and reports NULL ("no data yet") instead of failing.

// A dead Secure Enclave key: assertion apple_error with DeviceCheck code 0 or
// no coded error. proof_oversize means Apple returned a proof, so it is alive.
// Rotation additionally counts code 2; this view isolates the code-0 unknown.
const deadKey = (json: string) => `COALESCE(${json}->>'apple_error_source','')<>'proof_oversize'
 AND (COALESCE(jsonb_typeof(${json}->'apple_error'),'null')='null'
  OR (${json}->'apple_error'->>'domain'='devicecheck' AND ${json}->'apple_error'->>'code'='0'))`;

const macos27 = `(s.observation->>'os_major')::int>=27`;

const cohorts = `WITH scoped AS (
 SELECT e.id,e.stage,e.outcome,e.fields AS f,s.machine_id,s.observation AS o
 FROM app_attest_shadow_events e JOIN darkbloom_machine_sessions s ON s.session_id=e.session_id
 WHERE e.observed_at>=NOW()-$1::int*INTERVAL '1 day' AND e.stage IN ('ready','attestation','assertion','rollout') AND ${macos27}
), cohorts AS (
 SELECT scoped.*,CASE
  WHEN stage='ready' AND outcome='unsupported' AND f->>'availability_reason'='is_supported_false' THEN 'is_supported_false'
  WHEN stage='attestation' AND outcome='apple_invalid_key' THEN 'fresh_key_invalid_key'
  WHEN stage='assertion' AND outcome='apple_error' AND ${deadKey("f")} THEN 'dead_key_assertion'
  WHEN outcome='busy' THEN 'stalled_busy'
  WHEN stage='rollout' AND outcome='identity_required' THEN 'identity_required'
 END AS cohort FROM scoped
)`;

export async function appAttestDiagnosticCohorts(days: number) {
  return query<{ cohort: string; events: string; machines: string }>(`${cohorts}
    SELECT cohort,COUNT(*) AS events,COUNT(DISTINCT machine_id) AS machines
    FROM cohorts WHERE cohort IS NOT NULL GROUP BY cohort ORDER BY cohort`, [days]);
}

// How much of the window already carries the new ready-reply diagnostics, so
// an empty breakdown can be read as "not rolled out yet" rather than "zero".
export async function appAttestDiagnosticCoverage(days: number) {
  const [row] = await query<{ machines: string; ready_events: string; diagnosed_events: string; diagnosed_machines: string }>(`
    SELECT (SELECT COUNT(DISTINCT s.machine_id) FROM darkbloom_machine_sessions s
      WHERE s.last_seen>=NOW()-$1::int*INTERVAL '1 day' AND ${macos27}) AS machines,
    COUNT(*) AS ready_events,
    COUNT(*) FILTER(WHERE e.fields ?| ARRAY['process_started_at','previous_exit','start_reason','preflight','key_history']) AS diagnosed_events,
    COUNT(DISTINCT s.machine_id) FILTER(WHERE e.fields ?| ARRAY['process_started_at','previous_exit','start_reason','preflight','key_history']) AS diagnosed_machines
    FROM app_attest_shadow_events e JOIN darkbloom_machine_sessions s ON s.session_id=e.session_id
    WHERE e.observed_at>=NOW()-$1::int*INTERVAL '1 day' AND e.stage='ready' AND ${macos27}`, [days]);
  return row;
}

// `::` binds tighter than `->`, so JSON paths are parenthesized before casts.
const flag = (path: string) => `CASE WHEN jsonb_typeof(${path})='boolean' THEN (${path})::text END`;
const text = (path: string) => `NULLIF(${path}#>>'{}','')`;
const chain = `CASE WHEN jsonb_typeof(f->'native_error_chain')='array' THEN f->'native_error_chain' ELSE '[]'::jsonb END`;

// Top 12 values per cohort × dimension, plus the count of events that did not
// report the dimension (value NULL).
export async function appAttestDiagnosticBreakdown(days: number) {
  return query<BreakdownRow>(`${cohorts}, dims AS (
    SELECT c.cohort,c.id,c.machine_id,d.dimension,d.value FROM cohorts c CROSS JOIN LATERAL (VALUES
     ('launch_session',${text("f->'launch_session'")}),
     ('console_user_active',${flag("f->'console_user_active'")}),
     ('sip_enabled',${flag("f->'sip_enabled'")}),
     ('authenticated_root',${flag("f->'authenticated_root'")}),
     ('preflight.opt_in_entitlement',${flag("f->'preflight'->'opt_in_entitlement'")}),
     ('preflight.environment_entitlement',${text("f->'preflight'->'environment_entitlement'")}),
     ('preflight.profile_present',${flag("f->'preflight'->'profile_present'")}),
     ('preflight.profile_expired',${flag("f->'preflight'->'profile_expired'")}),
     ('preflight.bundle_path_class',${text("f->'preflight'->'bundle_path_class'")}),
     ('previous_exit',${text("f->'previous_exit'")}),
     ('start_reason',${text("f->'start_reason'")}),
     ('rebooted_since_last_success',${flag("f->'rebooted_since_last_success'")}),
     ('process_restarted_since_last_success',${flag("f->'process_restarted_since_last_success'")}),
     ('key_history.created_boot_matches',${flag("f->'key_history'->'created_boot_matches'")}),
     ('key_history.generations_last_24h',CASE WHEN jsonb_typeof(f->'key_history'->'generations_last_24h')='number' THEN
       CASE WHEN (f->'key_history'->>'generations_last_24h')::numeric<=1 THEN (f->'key_history'->>'generations_last_24h')::numeric::text
        WHEN (f->'key_history'->>'generations_last_24h')::numeric<=5 THEN '2-5'
        WHEN (f->'key_history'->>'generations_last_24h')::numeric<=20 THEN '6-20' ELSE '21+' END END),
     ('os_build',NULLIF(o->>'os_build','')),
     ('provider_version',COALESCE(NULLIF(f->>'reported_version',''),NULLIF(o->>'version',''))),
     ('chip_family',CASE WHEN COALESCE(NULLIF(f->>'reported_chip',''),NULLIF(o->>'chip','')) IS NOT NULL THEN
       COALESCE(substring(COALESCE(NULLIF(f->>'reported_chip',''),o->>'chip') FROM 'M[0-9]+'),'other') END),
     ('operation_stalled_seconds',CASE WHEN jsonb_typeof(f->'operation_stalled_seconds')='number' THEN
       CASE WHEN (f->>'operation_stalled_seconds')::numeric<60 THEN '<1m'
        WHEN (f->>'operation_stalled_seconds')::numeric<600 THEN '1-10m'
        WHEN (f->>'operation_stalled_seconds')::numeric<3600 THEN '10-60m' ELSE '1h+' END END),
     ('native_error_chain',(SELECT string_agg((x->>'domain')||':'||(x->>'code'),' → ' ORDER BY n)
       FROM jsonb_array_elements(${chain}) WITH ORDINALITY AS t(x,n)))
    ) d(dimension,value) WHERE c.cohort IS NOT NULL
    UNION ALL
    SELECT c.cohort,c.id,c.machine_id,'native_error_entry',entry.value FROM cohorts c
    LEFT JOIN LATERAL (SELECT DISTINCT (x->>'domain')||':'||(x->>'code') AS value
      FROM jsonb_array_elements(${chain}) x) entry ON TRUE
    WHERE c.cohort IS NOT NULL
  ), counted AS (
    SELECT cohort,dimension,value,COUNT(DISTINCT machine_id) AS machines,COUNT(DISTINCT id) AS events
    FROM dims GROUP BY cohort,dimension,value
  ), ranked AS (
    SELECT counted.*,row_number() OVER(PARTITION BY cohort,dimension ORDER BY value IS NULL,events DESC,value) AS rank FROM counted
  )
  SELECT cohort,dimension,value,machines,events FROM ranked WHERE rank<=12 OR value IS NULL
  ORDER BY cohort,dimension,value IS NULL,events DESC,value`, [days]);
}

// First dead-key failure per key in the window, classified against the key's
// last verified assertion. Prefer the coordinator-derived booleans; fall back
// to comparing archived boot_time/process_started_at for older rows. A reboot
// cannot happen within 60 s of the previous boot, so that tolerance absorbs
// clock adjustment without hiding real reboots.
const deaths = `WITH dead AS (
 SELECT DISTINCT ON (e.key_id) e.key_id,e.received_at,e.context AS c,s.machine_id,s.observation AS o
 FROM app_attest_evidence e JOIN darkbloom_machine_sessions s ON s.session_id=e.session_id
 WHERE e.received_at>=NOW()-$1::int*INTERVAL '1 day' AND e.action='assertion' AND e.outcome='apple_error'
  AND ${deadKey("e.context")} AND ${macos27}
 ORDER BY e.key_id,e.received_at
), compared AS (
 SELECT d.*,ok.received_at AS last_success_at,
  NULLIF(COALESCE(NULLIF(d.c->'status'->>'os_build',''),d.o->>'os_build'),'') AS os_build_after,
  NULLIF(COALESCE(NULLIF(ok.c->'status'->>'os_build',''),ok.o->>'os_build'),'') AS os_build_before,
  COALESCE(CASE WHEN jsonb_typeof(d.c->'rebooted_since_last_success')='boolean' THEN (d.c->>'rebooted_since_last_success')::boolean END,
   CASE WHEN jsonb_typeof(d.c->'boot_time')='number' AND jsonb_typeof(ok.c->'boot_time')='number'
    THEN abs((d.c->>'boot_time')::bigint-(ok.c->>'boot_time')::bigint)>60 END) AS rebooted,
  COALESCE(CASE WHEN jsonb_typeof(d.c->'process_restarted_since_last_success')='boolean' THEN (d.c->>'process_restarted_since_last_success')::boolean END,
   CASE WHEN jsonb_typeof(d.c->'process_started_at')='number' AND jsonb_typeof(ok.c->'process_started_at')='number'
    THEN (d.c->>'process_started_at')::bigint<>(ok.c->>'process_started_at')::bigint END) AS restarted
 FROM dead d LEFT JOIN LATERAL (
  SELECT v.received_at,v.context AS c,vs.observation AS o FROM app_attest_evidence v
  LEFT JOIN darkbloom_machine_sessions vs ON vs.session_id=v.session_id
  WHERE v.key_id=d.key_id AND v.action='assertion' AND v.outcome='verified' AND v.received_at<d.received_at
  ORDER BY v.received_at DESC LIMIT 1) ok ON TRUE
), classified AS (
 SELECT compared.*,CASE
  WHEN os_build_before IS NOT NULL AND os_build_after IS NOT NULL AND os_build_before<>os_build_after THEN 'os_change'
  WHEN rebooted THEN 'reboot'
  WHEN restarted THEN 'process_restart'
  WHEN rebooted IS NOT NULL AND restarted IS NOT NULL THEN 'no_restart'
  ELSE 'unknown' END AS classification
 FROM compared
)`;

export async function appAttestKeyDeathsByDay(days: number) {
  return query<DeathDayRow>(`${deaths}
    SELECT to_char(received_at AT TIME ZONE 'UTC','YYYY-MM-DD') AS day,classification,
    COUNT(*) AS keys,COUNT(DISTINCT machine_id) AS machines,
    COUNT(*) FILTER(WHERE c->>'previous_exit'='clean') AS clean_exit,
    COUNT(*) FILTER(WHERE c->>'previous_exit'='unclean') AS unclean_exit
    FROM classified GROUP BY day,classification ORDER BY day DESC,classification`, [days]);
}

export async function appAttestRecentKeyDeaths(days: number) {
  return query<{
    key_id: string; machine_id: string; received_at: string; last_success_at: string | null; classification: string;
    os_build_before: string | null; os_build_after: string | null; previous_exit: string | null;
    start_reason: string | null; launch_session: string | null; native_error_chain: string | null;
  }>(`${deaths}
    SELECT key_id,machine_id,received_at,last_success_at,classification,os_build_before,os_build_after,
    NULLIF(c->>'previous_exit','') AS previous_exit,NULLIF(c->>'start_reason','') AS start_reason,
    NULLIF(c->>'launch_session','') AS launch_session,
    (SELECT string_agg((x->>'domain')||':'||(x->>'code'),' → ' ORDER BY n) FROM jsonb_array_elements(
      CASE WHEN jsonb_typeof(c->'native_error_chain')='array' THEN c->'native_error_chain' ELSE '[]'::jsonb END)
      WITH ORDINALITY AS t(x,n)) AS native_error_chain
    FROM classified ORDER BY received_at DESC,key_id LIMIT 50`, [days]);
}

// Durable rotation records and whether a different key from the same scope
// (canonical machine, or account:<id>) later verified within 7 days.
export async function appAttestRotationOutcomes(days: number) {
  return query<{ reason: string; requested: string; scopes: string; replacement_attested: string; replacement_verified: string; median_seconds_to_verified: number | null }>(`
    WITH r AS (SELECT * FROM app_attest_key_rotations WHERE requested_at>=NOW()-$1::int*INTERVAL '1 day')
    SELECT r.reason,COUNT(*) AS requested,COUNT(DISTINCT r.machine_id) AS scopes,
    COUNT(*) FILTER(WHERE rep.attested IS NOT NULL) AS replacement_attested,
    COUNT(*) FILTER(WHERE rep.asserted IS NOT NULL) AS replacement_verified,
    percentile_cont(0.5) WITHIN GROUP(ORDER BY EXTRACT(EPOCH FROM rep.asserted-r.requested_at)) AS median_seconds_to_verified
    FROM r LEFT JOIN LATERAL (
     SELECT MIN(e.received_at) FILTER(WHERE e.action='attestation') AS attested,
      MIN(e.received_at) FILTER(WHERE e.action='assertion') AS asserted
     FROM darkbloom_machine_sessions s JOIN app_attest_evidence e ON e.session_id=s.session_id
      AND e.received_at>=r.requested_at AND e.received_at<r.requested_at+INTERVAL '7 days'
     WHERE s.last_seen>=r.requested_at AND e.outcome='verified' AND e.key_id<>r.key_id
      AND (s.machine_id=r.machine_id OR (r.machine_id LIKE 'account:%' AND s.account_id=substr(r.machine_id,9)))
    ) rep ON TRUE
    GROUP BY r.reason ORDER BY requested DESC,r.reason`, [days]);
}

// Coordinator rotation decisions (requested, rate_limited, cohort_excluded, …)
// and enrollment backoff, from the observation stream.
export async function appAttestRotationEvents(days: number) {
  return query<{ stage: string; outcome: string; events: string; machines: string }>(`
    SELECT e.stage,e.outcome,COUNT(*) AS events,COUNT(DISTINCT s.machine_id) AS machines
    FROM app_attest_shadow_events e LEFT JOIN darkbloom_machine_sessions s ON s.session_id=e.session_id
    WHERE e.observed_at>=NOW()-$1::int*INTERVAL '1 day'
     AND (e.stage='rotation' OR (e.stage='recovery' AND e.outcome='enrollment_backoff'))
    GROUP BY e.stage,e.outcome ORDER BY e.stage,events DESC,e.outcome`, [days]);
}

export interface PushReceiptRow {
  os_group: string; machines: string; token_true: string; token_false: string; token_no_data: string;
  pushes_0: string; pushes_1_3: string; pushes_4_10: string; pushes_over_10: string; pushes_no_data: string;
  age_under_1h: string; age_1_24h: string; age_over_24h: string; age_never_or_no_data: string; last_push_unanswered: string;
}

// Provider-side APNs code-identity push receipt for ALL OS versions (legacy
// macOS < 27 is the cohort that waits on pushes). One row per OS group from the
// latest ready event per machine in the window. push_history members are
// optional; a missing or non-numeric value counts as "no data". The latest push
// is unanswered when no reply was sent after it (reply age older than push age).
export async function appAttestPushReceipt(days: number) {
  return query<PushReceiptRow>(`WITH latest AS (
    SELECT DISTINCT ON (s.machine_id) s.machine_id,s.observation AS o,e.fields->'push_history' AS p
    FROM app_attest_shadow_events e JOIN darkbloom_machine_sessions s ON s.session_id=e.session_id
    WHERE e.observed_at>=NOW()-$1::int*INTERVAL '1 day' AND e.stage='ready'
    ORDER BY s.machine_id,e.observed_at DESC,e.id
  ), typed AS (
    SELECT CASE WHEN COALESCE((o->>'os_major')::int,0)=0 THEN 'unknown'
      WHEN (o->>'os_major')::int>=27 THEN '>=27' ELSE '<27' END AS os_group,
     CASE WHEN jsonb_typeof(p->'device_token_present')='boolean' THEN (p->>'device_token_present')::boolean END AS token,
     CASE WHEN jsonb_typeof(p->'pushes_received_last_24h')='number' AND (p->>'pushes_received_last_24h')::numeric>=0
      THEN (p->>'pushes_received_last_24h')::numeric END AS pushes,
     CASE WHEN jsonb_typeof(p->'last_push_received_age_seconds')='number' AND (p->>'last_push_received_age_seconds')::numeric>=0
      THEN (p->>'last_push_received_age_seconds')::numeric END AS push_age,
     CASE WHEN jsonb_typeof(p->'last_reply_sent_age_seconds')='number' AND (p->>'last_reply_sent_age_seconds')::numeric>=0
      THEN (p->>'last_reply_sent_age_seconds')::numeric END AS reply_age
    FROM latest
  )
  SELECT os_group,COUNT(*) AS machines,
   COUNT(*) FILTER(WHERE token) AS token_true,COUNT(*) FILTER(WHERE NOT token) AS token_false,
   COUNT(*) FILTER(WHERE token IS NULL) AS token_no_data,
   COUNT(*) FILTER(WHERE pushes=0) AS pushes_0,COUNT(*) FILTER(WHERE pushes BETWEEN 1 AND 3) AS pushes_1_3,
   COUNT(*) FILTER(WHERE pushes BETWEEN 4 AND 10) AS pushes_4_10,COUNT(*) FILTER(WHERE pushes>10) AS pushes_over_10,
   COUNT(*) FILTER(WHERE pushes IS NULL) AS pushes_no_data,
   COUNT(*) FILTER(WHERE push_age<3600) AS age_under_1h,COUNT(*) FILTER(WHERE push_age>=3600 AND push_age<=86400) AS age_1_24h,
   COUNT(*) FILTER(WHERE push_age>86400) AS age_over_24h,COUNT(*) FILTER(WHERE push_age IS NULL) AS age_never_or_no_data,
   COUNT(*) FILTER(WHERE push_age IS NOT NULL AND (reply_age IS NULL OR reply_age>push_age)) AS last_push_unanswered
  FROM typed GROUP BY os_group ORDER BY os_group`, [days]);
}
