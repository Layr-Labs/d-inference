# Prediction decision telemetry

> Last updated: 2026-09-07 · commit `53646bc9b`

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
| `projection_reason` | Ordinary-submit bypass only: `no_deadline`, `mode_off`, `unsupported_scheduler`, `multimodal`, `unmeasured_prefill`, `other`, or absent. The engine exposes no cause for an unbounded projection, so no cause is invented. |
| `observed_us` | Offset from the provider profile anchor when the bridge receives a verdict or observes pre-submit expiry. **Not the engine's atomic refusal time.** |
| `remaining_us` | Remaining deadline at that provider observation, clamped at zero. |
| `submit_remaining_us` | Remaining deadline immediately before the engine call. |
| `projected_service_us` | Returned finite service-duration projection. Absent when unavailable/unbounded. |
| `projected_prefill_tokens`, `projected_decode_tokens` | Engine-projected scheduled work through the target's first-token step, including work ahead of the target; not just the target request's tokens. |
| `prefill_tps`, `decode_tps` | Effective conservative rates passed to the engine after the existing policy adjustment. Missing/unusable rates remain absent. |

`provider-swift/Sources/ProviderCore/Inference/EngineV2Bridge+DeadlineDecision.swift`
records returned evidence before post-submit expiry/cancellation checks can
throw. Existing accepted-only stamps and projection fields keep their meaning;
`accepted` with `continuation=expired` can therefore coexist with a missing
old `engine_admitted_us` stamp. Ordinary submit uses `not_attempted` and never
fabricates projected work.

## Boundaries and compatibility

- These provider observations cover the engine bridge. Earlier loading or
  prompt-preparation failures outside it can still omit the object; later
  streaming failures remain represented by existing terminal fields.
- Offsets use local clocks. Do not subtract coordinator and provider offsets
  as if they shared an origin. The interval between submit and verdict receipt
  brackets the engine operation; its exact refusal instant is unavailable.
- Older providers omit the object. Older coordinators ignore the new optional
  object; schema remains 1. Unknown enums fold to `other`; numeric fields are
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
