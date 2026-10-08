# Coordinator environment audit

> Last updated: 2026-10-08

Read-only inspection found seven unused variables, one unused tuning threshold,
and a disabled-but-still-implemented dedicated-model policy in the production
coordinator environment. No production configuration, secrets, containers,
services or traffic were changed. The accompanying source cleanup retires the
policy and threshold; applying it to production remains a separate operation.

## Evidence and scope

| Surface | Observation |
|---|---|
| GCE host | `darkbloom-coordinator`, `us-east4-a`, project `darkbloom-mainnet`; running confidential VM |
| Health | `status=ok`, version `0.9.18`, build `f57a671856bd7a9dd3646e0c77db6ef46751c854` |
| Container | `coordinator`, running since `2026-10-07T03:50:20.39068651Z` |
| Image | `sha256:ea7450d4a426d82f4d64a7e19883bf310b6cc5c65d55bac3e519e4b6f9cb7418` |
| Host env file | `/etc/d-inference/env`: 163 assignments |
| Running container configuration | The same 163 names and set/empty states, plus `PATH` |
| Source comparison | Running build above and cleanup base `586f7e127deecc4552d15d27580a6e72e85b40db` |

Inspection used `gcloud compute instances describe`, IAP SSH, a filtered read of
the env file, filtered `docker inspect .Config.Env`, and the local `/health`
endpoint. Secret values were filtered on the host before output. Matching names
and set/empty states do not prove that arbitrary secret values match byte for
byte. The four policy values below were explicitly selected as non-secret.
This inventory covers the coordinator container and its entrypoint, not every
host service, developer shell, Cloud Build job or private external script.

## Removal decisions

All nine names below were present and nonempty in the host file and running
container configuration.

| Variable | Finding | Removal boundary |
|---|---|---|
| `EIGENINFERENCE_DEDICATED_MODELS` | Live value `none`; policy disabled. Old application code defaults to `gemma-4` when absent. | Retire the reader and routing policy before removing the opt-out. Keep the old value in the rollback env. |
| `EIGENINFERENCE_WARM_POOL_LOAD_DURATION_THRESHOLD` | Parsed and validated but never used by the warm-pool pressure/target calculations. | Remove field, reader, validator and required-manifest entry. Preserve load-duration EWMA and telemetry. |
| `EIGENINFERENCE_STEP_CA_ROOT` | No current reader; old ACME enrollment leg removed. | Host assignment can be removed; this does not authorize deleting certificate files or MicroMDM state. |
| `EIGENINFERENCE_STEP_CA_INTERMEDIATE` | Same retired ACME path. | Same boundary. |
| `EIGENINFERENCE_R2_SITE_PACKAGES_CDN_URL` | No current reader; Python/site-packages installer payload removed. | Host assignment can be removed; keep the active `EIGENINFERENCE_R2_CDN_URL`. |
| `EIGENINFERENCE_REFERRAL_SHARE_PCT` | Ignored; referral settlement uses the fixed store policy. A negative regression test deliberately retains this name. | Host assignment can be removed; do not remove the fixed accounting policy or its regression test. |
| `EIGENINFERENCE_CACHE_AFFINITY_TTL` | No current reader; not an alias for current cache-routing TTL. | Host assignment can be removed; leave `EIGENINFERENCE_CACHE_ROUTING_TTL` intact. |
| `EIGENINFERENCE_CACHE_AFFINITY_BONUS_MS` | No current reader; current affinity selection does not use this bonus. | Host assignment can be removed; do not translate it into a new scoring override. |
| `EIGENINFERENCE_PREFILL_KEEPALIVE_INTERVAL` | No reader in the coordinator, entrypoint or checked release tooling. | Host assignment can be removed; streaming and idle timeouts remain unchanged. |

Evidence at the running revision:

- [Application registry configuration](https://github.com/Layr-Labs/d-inference/blob/f57a671856bd7a9dd3646e0c77db6ef46751c854/coordinator/app/registry.go): default and `none` handling.
- [Warm-pool configuration](https://github.com/Layr-Labs/d-inference/blob/f57a671856bd7a9dd3646e0c77db6ef46751c854/coordinator/internal/registry/warmplan/config.go) and [planner](https://github.com/Layr-Labs/d-inference/blob/f57a671856bd7a9dd3646e0c77db6ef46751c854/coordinator/internal/registry/warmplan/planner.go): threshold only participates in validation, not pressure.
- [Enrollment](https://github.com/Layr-Labs/d-inference/blob/f57a671856bd7a9dd3646e0c77db6ef46751c854/coordinator/internal/provider/enrollment/enrollment_profile.go): removed ACME path.
- [Installer contract tests](https://github.com/Layr-Labs/d-inference/blob/f57a671856bd7a9dd3646e0c77db6ef46751c854/coordinator/tests/api/releases/contracts/install_test.go): retired Python payload.
- [Referral policy](https://github.com/Layr-Labs/d-inference/blob/f57a671856bd7a9dd3646e0c77db6ef46751c854/coordinator/billing/referral.go) and [regression](https://github.com/Layr-Labs/d-inference/blob/f57a671856bd7a9dd3646e0c77db6ef46751c854/coordinator/tests/billing/referral_contract_test.go): fixed settlement share.
- [Cache affinity](https://github.com/Layr-Labs/d-inference/blob/f57a671856bd7a9dd3646e0c77db6ef46751c854/coordinator/registry/selection/affinity.go): deterministic selection, not an env-configured score bonus.

The sanitized production reference also contained seven unsupported descriptor
names: `ENVIRONMENT`, `COORDINATOR_WS_URL`, `CONSOLE_URL`, `BASE_URL`, `MIN_TRUST`,
`MDM_ENABLED`, and `APPLE_SIGNING_IDENTITY`. None appeared in the live inventory.
They are not implemented aliases. Deployment classification, public URLs and
trust use their documented `EIGENINFERENCE_*` names; release signing uses its
workflow inputs. Removing these descriptor names is not a production mutation.

## Keep or investigate separately

| Settings | Decision and evidence |
|---|---|
| `EIGENINFERENCE_COLD_DISPATCH=false` | Keep the explicit off switch: absence enables cold dispatch. Reader: `coordinator/internal/inference/cold/policy.go`. |
| `EIGENINFERENCE_TTFT_ADMISSION_MODE=shadow`, `EIGENINFERENCE_TTFT_OCCUPANCY_ALPHA` | Keep observational controls. `enforce` is not additional enforcement in this implementation, but shadow metrics are active. Reader: `coordinator/registry/ttft_shadow.go`. |
| `EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_ONLY=true` | Keep the cutover guard; absence changes rail selection and credential fallback. Reader: `coordinator/billing/config.go`. |
| `EIGENINFERENCE_STRIPE_CONNECT_SECRET_KEY`, `EIGENINFERENCE_STRIPE_CONNECT_WEBHOOK_SECRET`, `EIGENINFERENCE_STRIPE_CONNECT_ACCOUNTS_WEBHOOK_SECRET` | Not proven removable. Legacy webhooks, reversals and reconciliation still use them; the cleanup base also has queued legacy withdrawals. Readers: `coordinator/api/billing/payouts/stripe_payouts_webhooks.go`, `coordinator/internal/billing/payoutrecovery/recovery_stripe.go`, `coordinator/api/billing/payouts/stripe_withdrawal_queue.go`. Removing only the API key can fail startup while webhook secrets remain. |
| `EIGENINFERENCE_STRIPE_CONNECT_RETURN_URL`, `EIGENINFERENCE_STRIPE_CONNECT_REFRESH_URL` | Keep despite the names: Global Payouts onboarding also uses them, including redirect validation. Readers: `coordinator/api/billing/payouts/connect_onboarding.go`, `coordinator/api/billing/payouts/global_payouts_onboarding.go`. |
| `EIGENINFERENCE_APP_ATTEST_QUALIFIED_BUILD_HASHES`, `EIGENINFERENCE_APP_ATTEST_QUALIFIED_CODE_HASHES` | Not proven removable. They are bootstrap fallbacks for builds without durable qualification rows. Durable records, including revocations, take precedence. Reader: `coordinator/internal/appattest/qualification/cache.go`. Qualification-row coverage was not queried. |
| `MICROMDM_API_KEY`, `EIGENINFERENCE_MDM_API_KEY` | Keep both: server and client credentials, not redundant aliases. Readers: `coordinator/deploy/start.sh`, `coordinator/mdm/config.go`. |
| `DD_APP_KEY` | No coordinator ingestion reader, but used by Datadog administration tooling (`deploy/datadog/apply-dev-dashboard.sh`). Removing its container copy is an operational-scope decision, not a global unused-variable finding. |

All other inventoried settings have coordinator, entrypoint or documented
tooling consumers. Disabled features and blank optional cache limits were not
classified as dead. In particular, secret delivery alternatives, App Attest,
Autopilot, base rewards, rate limits, health/capacity safeguards, sidecar resource
limits, profile signing and cache persistence remain intact.

## Applying the cleanup

Source cleanup does not edit the host env. `refresh-env.sh` preserves these
retired keys and their values; its existing exact-default migrations for other
settings remain unchanged. A human-approved configuration change must preserve
a root-only rollback copy, deploy a binary that ignores the retired policy, and
verify the selected image and env before removing its old opt-out. An older
binary must use its captured env, including `none`, on rollback.
Use the [coordinator deployment runbook](../operations/coordinator-deploy.md#retired-settings-and-rollback).
No secret deletion, key rotation, policy activation or production restart was
performed in this audit.

## Complete key-only inventory

These 163 names were present in both the host env file and the running
container configuration. Every assignment was nonempty except
`EIGENINFERENCE_CACHE_ROUTING_MAX_COST_FRACTION` and
`EIGENINFERENCE_CACHE_ROUTING_MAX_DISCOUNT_MS`. The container additionally had
the ordinary executable-search variable `PATH`.

```text
APNS_AUTH_KEY_P8_B64
APNS_ENFORCE_AFTER
APNS_KEY_ID
APNS_MODE
APNS_TEAM_ID
APNS_TOPIC
CORS_ORIGIN
DD_API_KEY
DD_APP_KEY
DD_ENV
DD_SERVICE
DD_SITE
DOMAIN
EIGENINFERENCE_ADMIN_EMAILS
EIGENINFERENCE_ADMIN_KEY
EIGENINFERENCE_APP_ATTEST_MDM_REMOVAL
EIGENINFERENCE_APP_ATTEST_QUALIFIED_BUILD_HASHES
EIGENINFERENCE_APP_ATTEST_QUALIFIED_CODE_HASHES
EIGENINFERENCE_APP_ATTEST_RECEIPT_KEY_ID
EIGENINFERENCE_APP_ATTEST_RECEIPT_KEY_PATH
EIGENINFERENCE_APP_ATTEST_ROLLOUT_PERCENT
EIGENINFERENCE_APP_ATTEST_SERVING
EIGENINFERENCE_APP_ATTEST_SHADOW
EIGENINFERENCE_AUTOPILOT_ENABLED
EIGENINFERENCE_AUTOPILOT_OBSERVE_ONLY
EIGENINFERENCE_BASE_REWARDS
EIGENINFERENCE_BASE_REWARDS_ACCOUNT_CAP
EIGENINFERENCE_BASE_REWARDS_K
EIGENINFERENCE_BASE_REWARDS_MIN_UPTIME
EIGENINFERENCE_BASE_REWARDS_POOL_MICRO
EIGENINFERENCE_BASE_URL
EIGENINFERENCE_CACHE_AFFINITY_BONUS_MS
EIGENINFERENCE_CACHE_AFFINITY_TTL
EIGENINFERENCE_CACHE_MASTER_KEY
EIGENINFERENCE_CACHE_ROUTING_ALLOWED_ARTIFACTS
EIGENINFERENCE_CACHE_ROUTING_MAX_COST_FRACTION
EIGENINFERENCE_CACHE_ROUTING_MAX_DISCOUNT_MS
EIGENINFERENCE_CACHE_ROUTING_MAX_HOLDERS
EIGENINFERENCE_CACHE_ROUTING_MAX_PLAN_QPS
EIGENINFERENCE_CACHE_ROUTING_MODE
EIGENINFERENCE_CACHE_ROUTING_PERCENT
EIGENINFERENCE_CACHE_ROUTING_PERSIST
EIGENINFERENCE_CACHE_ROUTING_TTL
EIGENINFERENCE_COLD_DISPATCH
EIGENINFERENCE_CONSOLE_URL
EIGENINFERENCE_DATABASE_URL
EIGENINFERENCE_DEDICATED_MODELS
EIGENINFERENCE_DRAIN_GRACE
EIGENINFERENCE_FIRST_CONTENT_SLA_ACCOUNTS
EIGENINFERENCE_HEALTH_EJECTION
EIGENINFERENCE_IPAPI_KEY
EIGENINFERENCE_MDM_API_KEY
EIGENINFERENCE_MDM_URL
EIGENINFERENCE_MEDIA_FETCH_ENABLED
EIGENINFERENCE_MIN_DECODE_TPS
EIGENINFERENCE_MIN_PROVIDER_VERSION
EIGENINFERENCE_MODEL_SOLO_TPS_SEED
EIGENINFERENCE_PORT
EIGENINFERENCE_PPROF_ADDR
EIGENINFERENCE_PREFILL_DECODE_RATIO
EIGENINFERENCE_PREFILL_KEEPALIVE_INTERVAL
EIGENINFERENCE_PRIVY_APP_ID
EIGENINFERENCE_PRIVY_APP_SECRET
EIGENINFERENCE_PRIVY_VERIFICATION_KEY
EIGENINFERENCE_PROMPT_CALIBRATION
EIGENINFERENCE_PROMPT_SIDECAR_ARTIFACT_BASE_URL
EIGENINFERENCE_PROMPT_SIDECAR_ARTIFACT_ROOT
EIGENINFERENCE_PROMPT_SIDECAR_ARTIFACT_TIMEOUT_MS
EIGENINFERENCE_PROMPT_SIDECAR_BINARY
EIGENINFERENCE_PROMPT_SIDECAR_ENABLED
EIGENINFERENCE_PROMPT_SIDECAR_HEADER_TIMEOUT_MS
EIGENINFERENCE_PROMPT_SIDECAR_HEALTH_FAILURE_THRESHOLD
EIGENINFERENCE_PROMPT_SIDECAR_HEALTH_INTERVAL_MS
EIGENINFERENCE_PROMPT_SIDECAR_HEALTH_TIMEOUT_MS
EIGENINFERENCE_PROMPT_SIDECAR_MAX_BODY_BYTES
EIGENINFERENCE_PROMPT_SIDECAR_MAX_CONCURRENCY
EIGENINFERENCE_PROMPT_SIDECAR_MAX_CONNECTIONS
EIGENINFERENCE_PROMPT_SIDECAR_MAX_LOADED_CONTRACTS
EIGENINFERENCE_PROMPT_SIDECAR_MAX_TOKENS
EIGENINFERENCE_PROMPT_SIDECAR_MEMORY_LIMIT_MIB
EIGENINFERENCE_PROMPT_SIDECAR_PRELOAD_TIMEOUT_MS
EIGENINFERENCE_PROMPT_SIDECAR_PROVISION_MAX_MODELS
EIGENINFERENCE_PROMPT_SIDECAR_PROVISION_WORKERS
EIGENINFERENCE_PROMPT_SIDECAR_RESTART_COOLDOWN_MS
EIGENINFERENCE_PROMPT_SIDECAR_RESTART_MAX_IN_WINDOW
EIGENINFERENCE_PROMPT_SIDECAR_RESTART_MAX_MS
EIGENINFERENCE_PROMPT_SIDECAR_RESTART_MIN_MS
EIGENINFERENCE_PROMPT_SIDECAR_RESTART_WINDOW_MS
EIGENINFERENCE_PROMPT_SIDECAR_SHUTDOWN_TIMEOUT_MS
EIGENINFERENCE_PROMPT_SIDECAR_SOCKET
EIGENINFERENCE_PROMPT_SIDECAR_STARTUP_TIMEOUT_MS
EIGENINFERENCE_PROMPT_SIDECAR_STDERR_MAX_BYTES
EIGENINFERENCE_PROMPT_SIDECAR_TIMEOUT_MS
EIGENINFERENCE_QUEUE_BEFORE_SHED
EIGENINFERENCE_QUEUE_MAX_DEPTH
EIGENINFERENCE_QUEUE_MAX_WAIT
EIGENINFERENCE_R2_CDN_URL
EIGENINFERENCE_R2_SITE_PACKAGES_CDN_URL
EIGENINFERENCE_REFERRAL_SHARE_PCT
EIGENINFERENCE_REJECT_MODELS
EIGENINFERENCE_RELEASE_KEY
EIGENINFERENCE_RESERVE_COMMIT_MODE
EIGENINFERENCE_ROUTING_CONCURRENCY
EIGENINFERENCE_SERVABILITY_GATE
EIGENINFERENCE_SERVICE_EXPECTED_OUTPUT_ADMISSION_CEILING
EIGENINFERENCE_SERVICE_EXPECTED_OUTPUT_ADMISSION_ENABLED
EIGENINFERENCE_SERVICE_EXPECTED_OUTPUT_ADMISSION_FLOOR
EIGENINFERENCE_SERVICE_EXPECTED_OUTPUT_ADMISSION_FRACTION
EIGENINFERENCE_SERVICE_RATE_LIMIT_BURST
EIGENINFERENCE_SERVICE_RATE_LIMIT_ITPM
EIGENINFERENCE_SERVICE_RATE_LIMIT_ITPM_BURST
EIGENINFERENCE_SERVICE_RATE_LIMIT_OTPM
EIGENINFERENCE_SERVICE_RATE_LIMIT_OTPM_BURST
EIGENINFERENCE_SERVICE_RATE_LIMIT_RPS
EIGENINFERENCE_SERVICE_RESERVATIONS_ENABLED
EIGENINFERENCE_SOFT_DELETE_MUTATIONS_ENABLED
EIGENINFERENCE_STATE_EXPORT_ENABLED
EIGENINFERENCE_STEP_CA_INTERMEDIATE
EIGENINFERENCE_STEP_CA_ROOT
EIGENINFERENCE_STRIPE_CANCEL_URL
EIGENINFERENCE_STRIPE_CONNECT_ACCOUNTS_WEBHOOK_SECRET
EIGENINFERENCE_STRIPE_CONNECT_REFRESH_URL
EIGENINFERENCE_STRIPE_CONNECT_RETURN_URL
EIGENINFERENCE_STRIPE_CONNECT_SECRET_KEY
EIGENINFERENCE_STRIPE_CONNECT_WEBHOOK_SECRET
EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_ENABLED
EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_FINANCIAL_ACCOUNT
EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_ONLY
EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_SECRET_KEY
EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_WEBHOOK_SECRET
EIGENINFERENCE_STRIPE_SECRET_KEY
EIGENINFERENCE_STRIPE_SUCCESS_URL
EIGENINFERENCE_STRIPE_WEBHOOK_SECRET
EIGENINFERENCE_TRUST_GEO_HEADERS
EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP
EIGENINFERENCE_TTFT_ADMISSION_MODE
EIGENINFERENCE_TTFT_HARD_REJECT
EIGENINFERENCE_TTFT_LIVE_DEADLINE_BASE_MS
EIGENINFERENCE_TTFT_OCCUPANCY_ALPHA
EIGENINFERENCE_WARM_POOL_CAPACITY_REJECT_THRESHOLD
EIGENINFERENCE_WARM_POOL_COLD_DISPATCH_THRESHOLD
EIGENINFERENCE_WARM_POOL_ENABLED
EIGENINFERENCE_WARM_POOL_HEADROOM
EIGENINFERENCE_WARM_POOL_HEADROOM_LOAD_WINDOWS
EIGENINFERENCE_WARM_POOL_HEADROOM_MAX_PROVIDERS
EIGENINFERENCE_WARM_POOL_INTERVAL
EIGENINFERENCE_WARM_POOL_LOAD_DURATION_THRESHOLD
EIGENINFERENCE_WARM_POOL_MAX_GLOBAL_PENDING_LOADS
EIGENINFERENCE_WARM_POOL_MAX_LOADS_PER_TICK
EIGENINFERENCE_WARM_POOL_MIN_DWELL
EIGENINFERENCE_WARM_POOL_MIN_WARM
EIGENINFERENCE_WARM_POOL_OBSERVE_ONLY
EIGENINFERENCE_WARM_POOL_QUEUE_AGE_THRESHOLD
EIGENINFERENCE_WARM_POOL_SPECULATIVE_START_THRESHOLD
EIGENINFERENCE_WARM_POOL_SPECULATIVE_WIN_THRESHOLD
EIGENINFERENCE_WARM_POOL_TTFT_MISS_THRESHOLD
EIGENINFERENCE_WARM_POOL_WARM_SATURATION_THRESHOLD
MDM_PUSH_P12_B64
MICROMDM_API_KEY
MNEMONIC
MODEL_REGISTRY_PUBLISHING_KEY
PROFILE_SIGNING_P12_B64
PROFILE_SIGNING_P12_PASSWORD
```
