# Prediction decision telemetry

> Last updated: 2026-09-29 · commit `a8aa6bb33`

Optional attempt records compare what the coordinator selected with what the
provider decided. They explain decisions; they do not establish whether a
refused request would have completed on time.

## Coordinator fields

`coordinator/api/profiler_prediction.go` (`recordPredictivePolicy`) records
request policy. `coordinator/registry/attempt_profile_prediction.go` keeps
observations under the attempt lock; `coordinator/api/profiler_record.go`
(`buildProfileRecord`) persists them with existing request and attempt IDs.

| Field in `request_profiles` | Meaning |
|---|---|
| `admission_mode` | `hard` or `soft`, from the actual `ttftHardReject` switch. Empty means unknown historical/unobserved state. This is unrelated to the shadow-prediction mode. |
| `predictive_bypass` | `none`, `self_route`, `prefer_owner`, or `media`. Records the applicable request exception even if the switch is soft; precedence is self-route, prefer-owner, media. Empty means unknown. |
| `reservation_ttft_ceiling_ms` | `PendingRequest.MaxTTFTMs` when direct reservation returns or a queue assignment succeeds. Queue rejection exits leave it unobserved. Zero means the predictive ceiling is disabled; NULL means unobserved. It is not a new remaining-time calculation. |
| `dispatch_budget_ms` | Exact positive budget encoded when the writer constructs this attempt's envelope. NULL when no positive budget was encoded, including expiry before construction. A constructed envelope does not prove a successful socket write or provider receipt; use existing write/acceptance stamps. |
| Existing `predicted_ttft_ms`, `raw_ttft_ms`, `snapshot_age_ms` | Selected coordinator prediction and source-state age; no formulas or calibration are changed by recording the new fields. |

`coordinator/api/provider_wire.go` (`providerInferenceFrameBuilder`) captures
the attempt pointer before enqueue and records the envelope budget after
serialization. Retries, backups and queue dispatch retain their own attempt
identity. First-write-wins observations and detached snapshots prevent late
writer activity from mutating an already-built row.

## Provider fields

`profile.deadline_decision` is an optional schema-1 object carried on existing
terminal messages. Sources: `coordinator/protocol/profile_deadline.go`
(`DeadlineDecision`) and
`provider-swift/Sources/ProviderCore/Protocol/DeadlineDecisionProfile.swift`.

| Field | Meaning |
|---|---|
| `verdict` | `accepted`, `deadline_unreachable`, `expired_before_submit`, `cancelled`, `other`. `cancelled` without a returned verdict does not prove the engine never accepted. |
| `continuation` | `expired`, `cancelled`, `other`, or absent. Annotates a returned verdict when the bridge's immediate continuation is stopped; it does not replace the verdict. |
| `projection` | `bounded`, `unbounded`, `not_attempted`, `other`, or absent. Unbounded is distinct from a measured large duration. |
| `projection_reason` | Ordinary-submit bypass only: `no_deadline`, `mode_off`, `unsupported_scheduler`, `multimodal`, `unmeasured_prefill`, `other`, or absent. It does not describe an engine projection failure. |
| `unbounded_reason` | Optional closed engine cause for `projection=unbounded`, listed below. Missing means the engine supplied no cause; it is never reconstructed from occupancy or remaining time. Unknown future values fold to `other`. |
| `observed_us` | Offset from the provider profile anchor when the bridge receives a verdict or observes pre-submit expiry. **Not the engine's atomic refusal time.** |
| `remaining_us` | Remaining deadline at that provider observation, clamped at zero. |
| `submit_remaining_us` | Remaining deadline immediately before the engine call. |
| `projected_service_us` | Returned finite service-duration projection. Absent when unavailable/unbounded. |
| `projected_prefill_tokens`, `projected_decode_tokens` | Engine-projected scheduled work through the target's first-token step, including work ahead of the target; not just the target request's tokens. |
| `prefill_tps`, `decode_tps` | Effective conservative rates passed to the engine after the existing policy adjustment. Missing/unusable rates remain absent. |

`provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/EngineV2Bridge+DeadlineDecision.swift`
records returned evidence before post-submit expiry/cancellation checks can
throw. Existing accepted-only stamps and projection fields keep their meaning;
`accepted` with `continuation=expired` can therefore coexist with a missing
old `engine_admitted_us` stamp. Ordinary submit uses `not_attempted` and never
fabricates projected work.

### Unbounded projection causes

`unbounded_reason` reports the first failed guard family. It does not prove
that a refused request could have completed, nor identify the ultimate cause
of an inconsistent scheduler state. The SDK creates these values in
`firstTokenWorkProjection` and the engine's duration/capacity conversion; Swift and Go share the
[closed vocabulary fixture](../../coordinator/protocol/testdata/deadline_unbounded_reasons.json).

| Cause | Guard that failed |
|---|---|
| `unsupported_scheduler` | Required scheduler configuration or authoritative projection support is unavailable. |
| `target_missing` | The incoming target has no scheduler record. |
| `invalid_in_flight_assignment` | In-flight work has an invalid count, missing owner, or no remaining known work. |
| `inconsistent_token_cursor` | A computed cursor cannot be reconciled with launched work and known tokens. |
| `unowned_pending_sample` | A pending sample has no corresponding in-flight assignment. |
| `multimodal_work` | Multimodal work cannot be bounded by this text-token projection. |
| `invalid_prefix_reservation` | A projected prefix/capacity reservation cannot be represented. |
| `invalid_projection_assignment`, `invalid_projection_transition` | The projection cannot construct an assignment or advance a row consistently. |
| `projection_arithmetic` | Projected work/count arithmetic fails its bounds. |
| `chained_step_unprojectable` | An additional chained decode step cannot be bounded. |
| `iteration_limit` | The bounded projection simulation reaches its complexity limit. |
| `prefix_geometry_blocked` | Prefix replay geometry prevents progress under the projected chunk policy. |
| `speculation_bound_missing` | Speculative decoding has no configured draft-work upper bound. |
| `no_scheduling_progress` | No row can be assigned work in the projected step. |
| `target_not_sampled` | The target leaves the projection without a first sampled token. |
| `invalid_work_totals` | Projected phase/step totals fail engine validation. |
| `capacity_model_unsupported` | The configured capacity implementation cannot supply the required guarantee. |
| `capacity_not_guaranteed` | The physical capacity projection cannot guarantee its reservation operations. |
| `prefill_rate_unavailable`, `decode_rate_unavailable` | A needed phase has no finite positive usable rate. |
| `service_duration_invalid`, `service_duration_underflow` | Work cannot be converted to a valid representable duration. |
| `other` | The receiver does not recognize a future cause. |

Bounded decisions and ordinary-submit bypasses do not generate this field.
An older engine's reasonless unbounded result keeps it absent. The field adds
no tensor reads, prompt text, token IDs, or extra scheduling passes. The same
unbounded result still refuses admission, with the same deadline and memory
guards.

On the read replica, use a bounded read-only diagnostic query after both
components are released:

```sql
BEGIN READ ONLY;
SET LOCAL statement_timeout = '15s';
SET LOCAL lock_timeout = '1s';
SELECT model,
       COALESCE(provider_profile->'deadline_decision'->>'unbounded_reason',
                'not_reported') AS unbounded_reason,
       count(*) AS retained_attempts
FROM request_profiles
WHERE created_at >= now() - interval '15 minutes'
  AND provider_profile_valid
  AND provider_profile->'deadline_decision'->>'projection' = 'unbounded'
GROUP BY 1, 2 ORDER BY 3 DESC;
ROLLBACK;
```

These are retained attempt profiles, not distinct customer requests or a
count of proven false rejections. Missing historical reasons remain
`not_reported`; the change does not reconstruct earlier records.

## Boundaries and compatibility

- These provider observations cover the engine bridge. Earlier loading or
  prompt-preparation failures outside it can still omit the object; later
  streaming failures remain represented by existing terminal fields.
- Offsets use local clocks. Do not subtract coordinator and provider offsets
  as if they shared an origin. The interval between submit and verdict receipt
  brackets the engine operation; its exact refusal instant is unavailable.
- Older providers omit the object or its new cause field. Older coordinators
  ignore the optional `unbounded_reason` field; schema remains 1. Unknown enums fold to `other`; numeric fields are
  bounded and free-form provider text is not persisted. The full profile cap
  remains 4,096 bytes. Sources: `coordinator/api/profiler_provider_deadline.go`
  (`storeDeadlineDecision`) and `coordinator/protocol/profile.go`.
- Existing profiler enablement, retention, sampling, asynchronous persistence
  and loss limits remain in effect. Refusals/retries are retained by existing
  rules when profiling is enabled; this is not an unsampled traffic ledger.
- No error codes, prediction coefficients, provider acceptance policy, retry
  policy, billing, or public response bodies change because of these fields.

## Storage and rollout

`coordinator/store/postgres.go` adds three columns idempotently. Historical
budgets/ceilings stay NULL and historical bypass stays empty. Provider fields
use existing `provider_profile` JSONB after the allowlist validation; no new
telemetry service or table is introduced.

Deploying coordinator support first makes later provider observations readable.
Both components must carry the change for paired evidence. A rollback leaves
columns present and optional fields unknown; it does not reconstruct history.
The manually applied `coordinator/store/migrations/request_waterfall.sql`
appends the three new outputs, preserving previous view-column positions. It
is not executed at coordinator startup.

For existing pipeline behavior see [system profiler](../architecture/system-profiler.md).
