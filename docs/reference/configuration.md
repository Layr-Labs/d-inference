# Configuration reference

> Last updated: 2026-09-05 · commit `120ecc9c2`

Every environment variable read by the coordinator, the provider CLI
(`darkbloom`), console-ui and admin-ui: accepted values, the compiled default,
the code that reads it, and its effect. Defaults are the fallbacks at the cited
symbol; a production or dev host may pin a different value in its environment
file. Secrets are named, never valued. Unless a row says *live*, the variable is
read once at process start and a restart applies a change.

## Where values are set

| Component | Where the process gets its environment |
|---|---|
| Coordinator, production | `/etc/d-inference/env` (root-only, boot disk) on the Confidential VM. Secrets are placed by hand; `deploy/gcp/prod/refresh-env.sh` runs before Docker at every boot, adds any key from `deploy/gcp/prod/release-env-defaults` that is absent, migrates a few exact historical values, never overwrites an operator-set value, and refuses to run when a required key is missing or empty. The list of keys production must have is maintained once in [`../operations/coordinator-deploy.md#environment-file`](../operations/coordinator-deploy.md#environment-file). The container entrypoint `coordinator/deploy/start.sh` reads `USER_PERSISTENT_DATA_PATH`, `MICROMDM_API_KEY`, `MDM_PUSH_P12_B64`, `DOMAIN` and `EIGENINFERENCE_MDM_WEBHOOK_SECRET` itself before it `exec`s the `coordinator` binary; everything else is read by Go code. |
| Coordinator, dev | Same file layout on the dev VM, written by `deploy/gcp/refresh-env.sh`; see [`../operations/dev-environment.md`](../operations/dev-environment.md). |
| Coordinator, local | Whatever shell exports `go run ./coordinator/cmd/coordinator` inherits. `EIGENINFERENCE_ALLOW_MEMORY_STORE=true` is the only way to start without a database. |
| Provider CLI, `darkbloom start --foreground` | The invoking shell's environment, minus the 13 variables scrubbed by `provider-swift/Sources/ProviderCore/Security/EnvironmentScrubber.swift`. Every `DARKBLOOM_*` row below applies. |
| Provider CLI, installed LaunchAgent | `darkbloom start` (daemon mode) writes a launchd plist whose `EnvironmentVariables` are built by `passthroughEnvironment` in `provider-swift/Sources/ProviderCore/Service/LaunchAgent.swift`: only the allow-list `passthroughEnvKeys` + `inferencePassthroughEnvKeys` is copied from the operator's shell (`DARKBLOOM_PREFIX_CACHE`, `DARKBLOOM_MLX_RESOURCE_DEBUG`, `DARKBLOOM_CBV2_PAGED_KV`, `DARKBLOOM_CBV2_MTP`, `DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS`, `DARKBLOOM_KV_BACKEND_GUARD`, `DARKBLOOM_MLX_CACHE_LIMIT_GB`, `DARKBLOOM_MLX_MEMORY_RESERVE_GB`, `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS`, `DARKBLOOM_PREFILL_DEADLINE_MODE`), plus `MLX_GATHER_QMM_EXPERT_SLICES` only when it is exactly `1`. `PATH` is deliberately dropped. The watchdog plist (`provider-swift/Sources/ProviderCore/Service/WatchdogAgent.swift`) additionally forwards `DARKBLOOM_NO_UPDATE_CHECK`. Every other provider variable is inert under launchd. |
| Provider CLI, `provider.toml` | `~/.config/darkbloom/provider.toml` (`ConfigManager` in `provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift`) is the durable configuration; a variable that overrides a config key says so in its Effect cell (`DARKBLOOM_CBV2_PAGED_KV`, `DARKBLOOM_CBV2_MTP`, `DARKBLOOM_MLX_MEMORY_RESERVE_GB`, `DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL`). |
| console-ui | Next.js `.env*` files or the hosting build environment (Vercel-style). Every console-ui variable is `NEXT_PUBLIC_*` or build-tooling: inlined at **build** time, so changing one requires a rebuild. There is no server-only secret; a gitignored `.env.local` in `console-ui/` is the only local file and no `.env.example` exists. |
| admin-ui | Server-only **runtime** variables read by React Server Components on each request; set them in `.env*` or the host environment. `NODE_ENV` is set by Next. |

## Coordinator

### Core server

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `EIGENINFERENCE_PORT` | TCP port | `8080` | `coordinator/api/server_config.go` (`ReadServerConfig`) | Listen port for the HTTP API and the provider WebSocket. |
| `EIGENINFERENCE_BASE_URL` | URL | unset — derived per request from `Host` and `X-Forwarded-Proto` | `coordinator/api/server_config.go` (`ReadServerConfig`); `coordinator/api/server.go` (`resolveBaseURL`) | Public origin templated into the served `/install.sh` and other self-referencing URLs. |
| `EIGENINFERENCE_CONSOLE_URL` | URL | unset — `<scheme>://<Host>/link` is derived per request | `coordinator/api/server_config.go` (`ReadServerConfig`); `coordinator/api/device_auth.go` | Console origin used to build the device-code `verification_uri` (`<console>/link`). |
| `CORS_ORIGIN` | origin | `https://console.darkbloom.dev` (applied in `corsMiddleware`) | `coordinator/api/server_config.go` (`ReadServerConfig`); `coordinator/api/server.go` (`corsMiddleware`) | The single origin allowed for credentialed CORS; public read-only GETs stay wildcard. |
| `EIGENINFERENCE_DRAIN_GRACE` | Go duration | `10m` (`DefaultDrainGrace`) | `coordinator/api/drain.go` (`DrainGraceFromEnv`) | How long shutdown waits for in-flight requests after SIGTERM before `http.Server.Shutdown`; `0` skips the wait. |
| `EIGENINFERENCE_ROUTING_CONCURRENCY` | integer ≥ 2 | `runtime.NumCPU()` (min 2) | `coordinator/cmd/coordinator/main.go`; `coordinator/api/server.go` (`DefaultRoutingConcurrency`) | Cap on concurrent routing scans. |
| `EIGENINFERENCE_PPROF_ADDR` | `host:port` | unset (off) | `coordinator/cmd/coordinator/main.go` (`startPprofListener`) | Serves `net/http/pprof` on a separate listener; bind loopback or firewall it. A successful listener enables mutex sampling at fraction `100` and block sampling at rate `1_000_000` ns (`enableContentionProfiling`). |

### Database, store and persistent disk

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `EIGENINFERENCE_DATABASE_URL` | Postgres DSN (secret) | unset | `coordinator/store/config.go` (`ReadConfig`); `coordinator/cmd/coordinator/main.go` | Selects the Postgres store and runs migrations at boot; see [`../architecture/storage.md`](../architecture/storage.md). Required unless the memory store is allowed. |
| `EIGENINFERENCE_ALLOW_MEMORY_STORE` | `true` | `false` | `coordinator/store/config.go` (`ReadConfig`, `Check`) | Permits the non-durable in-memory store when no DSN is set (tests and local dev only); startup refuses otherwise. |
| `USER_PERSISTENT_DATA_PATH` | directory | `/mnt/disks/userdata` | `coordinator/deploy/start.sh`; `coordinator/api/trust_reuse_journal.go` (`resolveTrustReuseRevocationJournalPath`); `coordinator/api/admin_state_export.go` (`resolveStateExportRoot`) | Persistent disk root, symlinked to `/data`; parent of the MicroMDM state, the trust-reuse journal and the state-export root. |
| `EIGENINFERENCE_TRUST_REUSE_REVOCATION_JOURNAL_PATH` | file path | `<persist>/coordinator/trust-reuse-hard-untrust.v1.jsonl` | `coordinator/api/trust_reuse_journal.go` (`resolveTrustReuseRevocationJournalPath`) | Location of the hard-untrust revocation journal; startup refuses when the journal is unusable. |
| `EIGENINFERENCE_STATE_EXPORT_ENABLED` | `true` | unset (route 404s) | `coordinator/api/admin_state_export.go` (`handleAdminStateExport`) | Master switch for `GET /v1/admin/state-export`; see [`../operations/state-export.md`](../operations/state-export.md). |
| `EIGENINFERENCE_STATE_EXPORT_RECIPIENT` | `age1…` public recipient | unset | `coordinator/api/admin_state_export.go` (`handleAdminStateExport`) | Encrypts the export to this recipient; without it the route answers 412 unless plaintext is allowed. |
| `EIGENINFERENCE_STATE_EXPORT_ALLOW_PLAINTEXT` | `true` | `false` | `coordinator/api/admin_state_export.go` (`handleAdminStateExport`) | Allows an unencrypted zip when no recipient is configured. |
| `EIGENINFERENCE_STATE_EXPORT_ROOT` | directory | `USER_PERSISTENT_DATA_PATH`, else `/mnt/disks/userdata` | `coordinator/api/admin_state_export.go` (`resolveStateExportRoot`) | Overrides the directory that is archived (tests). |

### Auth: admin key, Privy, release key, sender encryption

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `EIGENINFERENCE_ADMIN_KEY` | secret | unset (warning; no seeded key) | `coordinator/store/config.go` (`ReadConfig`); `coordinator/api/server_config.go` (`ReadServerConfig`); `coordinator/cmd/coordinator/main.go` (`SeedKey`) | Bootstrap admin API key seeded into `api_keys`; bearer token for `/v1/admin/*`, release registration and state export. |
| `EIGENINFERENCE_ADMIN_EMAILS` | comma-separated emails | unset | `coordinator/api/server_config.go` (`ReadServerConfig`, `ParseCommaList`) | Privy accounts with these emails get admin on console-facing admin routes. |
| `EIGENINFERENCE_RELEASE_KEY` | secret | unset | `coordinator/api/server_config.go` (`ReadServerConfig`); `coordinator/api/release_handlers.go` | Bearer token accepted (constant-time) for release registration in addition to the admin key. |
| `EIGENINFERENCE_PRIVY_APP_ID` | string | unset (Privy auth off) | `coordinator/auth/config.go` (`ReadConfig`) | Enables Privy JWT verification; also the expected JWT audience. |
| `EIGENINFERENCE_PRIVY_APP_SECRET` | secret | unset | `coordinator/auth/config.go` (`ReadConfig`) | Basic-auth credential for Privy REST calls. |
| `EIGENINFERENCE_PRIVY_VERIFICATION_KEY` | PEM ES256 public key | unset; required when the app id is set (`Check`) | `coordinator/auth/config.go` (`ReadConfig`) | Key that Privy access tokens are verified against. |
| `EIGENINFERENCE_PRIVY_VERIFICATION_KEY_FILE` | file path | unset | `coordinator/auth/config.go` (`ReadConfig`) | Reads the PEM from a file, overriding the inline value. |
| `MNEMONIC`, `EIGENINFERENCE_MNEMONIC` | BIP39 phrase (secret) | unset (sender→coordinator encryption disabled) | `coordinator/billing/config.go` (`ReadConfig`); `coordinator/cmd/coordinator/main.go` (`e2e.DeriveCoordinatorKey`) | Derives the X25519 key served at `GET /v1/encryption-key`; `MNEMONIC` wins when both are set. See [`../architecture/security/encryption.md`](../architecture/security/encryption.md). |

### MDM, attestation and APNs

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `MICROMDM_API_KEY` | secret | unset (MicroMDM is not started) | `coordinator/deploy/start.sh` | Starts the in-container MicroMDM with this API key; must be byte-identical to `EIGENINFERENCE_MDM_API_KEY`. |
| `MDM_PUSH_P12_B64` | base64 PKCS#12, URL-safe alphabet accepted (secret) | unset | `coordinator/deploy/start.sh` | Decoded on first boot into `/data/micromdm/push.crt` and `push.key` and uploaded to MicroMDM. |
| `DOMAIN` | hostname | `localhost` | `coordinator/deploy/start.sh` | MicroMDM `-server-url https://$DOMAIN`. |
| `EIGENINFERENCE_MDM_URL` | URL | unset (MDM verification off) | `coordinator/mdm/config.go` (`ReadConfig`) | Enables the MicroMDM client, the verification scheduler and the webhook; see [`../architecture/security/enrollment.md`](../architecture/security/enrollment.md). |
| `EIGENINFERENCE_MDM_API_KEY` | secret | compiled placeholder (`defaultMDMApiKey`) | `coordinator/mdm/config.go` (`ReadConfig`) | API key for MicroMDM calls; production sets a real key. |
| `EIGENINFERENCE_MDM_WEBHOOK_SECRET` | secret | unset (warning; webhook relies on the CommandUUID gate) | `coordinator/cmd/coordinator/main.go`; `coordinator/deploy/start.sh` | Shared secret MicroMDM must present on `/v1/mdm/webhook` (`?token=` or `X-Webhook-Token`); `start.sh` appends it to the webhook URL. |
| `EIGENINFERENCE_MDM_SCHEDULER_WORKERS` | integer 1–12 | `12` | `coordinator/api/server_config.go` (`readMDMSchedulerConfig`) | Verification worker pool size (values above 12 clamp down). |
| `EIGENINFERENCE_MDM_SCHEDULER_QUEUE_CAPACITY` | integer 1–4096 | `4096` | `coordinator/api/server_config.go` (`readMDMSchedulerConfig`) | Verification queue capacity (clamped). |
| `EIGENINFERENCE_MDM_INITIAL_SPREAD_MIN`, `EIGENINFERENCE_MDM_INITIAL_SPREAD_MAX` | Go durations, min ≤ max ≤ 30m | `5s`, `5m` | `coordinator/api/server_config.go` (`readMDMSchedulerConfig`) | Jitter window for a provider's first verification; an invalid pair resets both. |
| `EIGENINFERENCE_MDM_CLAIM_TTL` | Go duration 2m–15m | `3m` | `coordinator/api/server_config.go` (`readMDMSchedulerConfig`) | Lease on a claimed verification job. |
| `PROFILE_SIGNING_P12_B64`, `PROFILE_SIGNING_P12_PATH`, `PROFILE_SIGNING_P12_PASSWORD` | base64 or path to PKCS#12, password (secrets) | unset (profiles served unsigned) | `coordinator/profilesign/signer.go` (`LoadFromEnv`) | CMS-signs the `/v1/enroll` `.mobileconfig`. |
| `APNS_KEY_ID`, `APNS_TEAM_ID` | Apple key id, team id | unset (code-identity attestation off) | `coordinator/cmd/coordinator/main.go` (`loadAPNsAttestor`) | Both required to construct the APNs attestor; see [`../architecture/security/attestation.md`](../architecture/security/attestation.md). |
| `APNS_AUTH_KEY_P8_B64`, `APNS_AUTH_KEY_P8_PATH` | base64 or path to the `.p8` (secret) | unset (attestor disabled) | `coordinator/cmd/coordinator/main.go` (`loadAPNsAttestor`) | The APNs auth key; the base64 form wins. |
| `APNS_TOPIC` | bundle id | `io.darkbloom.provider` | `coordinator/cmd/coordinator/main.go` (`loadAPNsAttestor`) | APNs topic for code-identity pushes. |
| `APNS_MODE` | `background`, `alert` | `background` | `coordinator/cmd/coordinator/main.go` (`loadAPNsAttestor`) | Push type used for the challenge. |
| `APNS_ENFORCE_AFTER` | RFC 3339 timestamp | unset (grace: measured, never blocks) | `coordinator/cmd/coordinator/main.go` (`parseAPNsEnforceAfter`) | After this instant un-attested providers are not routed; a malformed value refuses startup. |
| `EIGENINFERENCE_TRUST_REUSE_WINDOW` | Go duration > 0 | `5m` | `coordinator/api/trust_reuse.go` (`trustReuseWindowFromEnv`) | How long a reconnecting provider may reuse its previous trust decision. |
| `EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP` | Go duration 0–120s | `90s` (values above 120s clamp down) | `coordinator/api/trust_reuse.go` (`trustReuseReconnectGapFromEnv`) | Maximum contiguous offline gap that still counts as continuity; `0` disables reuse. |
| `EIGENINFERENCE_TRUST_GEO_HEADERS` | `1` | unset | `coordinator/api/provider_geo.go` (`newProviderGeoResolverFromEnv`) | Trust proxy-supplied client-IP headers when geolocating providers. |
| `EIGENINFERENCE_IPAPI_KEY` | secret | unset (free ip-api.com tier) | `coordinator/api/provider_geo.go` (`newProviderGeoResolverFromEnv`) | Uses the keyed `pro.ip-api.com` endpoint for provider geolocation. |

### Release policy, version floor and binary hashes

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `EIGENINFERENCE_MIN_PROVIDER_VERSION` | semver | unset (no floor) | `coordinator/api/server_config.go` (`ReadServerConfig`); `coordinator/api/provider.go` | Providers below this version are refused at registration and excluded from routing; surfaced to operators in `/v1/me`. |
| `EIGENINFERENCE_RELEASE_POLICY_MODE` | `shadow`, `enforce` | `shadow` | `coordinator/cmd/coordinator/main.go` | Whether missing application evidence blocks routing; see [`../operations/release-policy-rollout.md`](../operations/release-policy-rollout.md). |
| `EIGENINFERENCE_RELEASE_POLICY_ENFORCE_GRACE` | Go duration ≥ 20m (raise-only) | `20m` | `coordinator/cmd/coordinator/main.go` | Boot grace before enforcement bites; shorter values clamp up to 20m. |
| `EIGENINFERENCE_BINARYHASH_ENFORCE` | `true` | `false` | `coordinator/cmd/coordinator/main.go` (`SetBinaryHashEnforcement`) | Re-enables legacy derouting on a self-reported `binaryHash` mismatch (rollback only). |
| `EIGENINFERENCE_KNOWN_BINARY_HASHES` | comma-separated hashes | unset | `coordinator/cmd/coordinator/main.go` (`AddKnownBinaryHashes`) | Extra known-good provider binary hashes beyond the active releases in the store. |
| `EIGENINFERENCE_KNOWN_TEMPLATE_HASHES` | `name=hash,…`; a repeated name accepts every listed hash | unset | `coordinator/cmd/coordinator/main.go` (`SetRuntimeManifest`) | Replaces the store-built [runtime manifest](../architecture/security/attestation.md#runtime-manifest) at boot; discarded by the next release registration or deactivation, which rebuilds the union from active releases. |

### Routing, admission and TTFT

Trust floor, model routing and per-request quality:

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `EIGENINFERENCE_MIN_TRUST` | `none`, `self_signed`, `hardware` | `hardware` (`registry.New`) | `coordinator/registry/config.go` (`ReadConfig`, `Check`) | Minimum trust level a provider needs to receive public traffic; an unknown value refuses startup. |
| `EIGENINFERENCE_DEDICATED_MODELS` | comma-separated family patterns, or `none` | `gemma-4` | `coordinator/cmd/coordinator/main.go`; `coordinator/registry/dedicated_models.go` (`ParseDedicatedModels`) | Model families that get dedicated-provider routing; `none` disables. |
| `EIGENINFERENCE_REJECT_MODELS` | comma-separated model ids | unset | `coordinator/cmd/coordinator/main.go` (`SetRejectModels`) | Sheds the listed models with 429 at admission. |
| `EIGENINFERENCE_MIN_DECODE_TPS` | float ≥ 0 (`0` disables) | `15` | `coordinator/cmd/coordinator/main.go` (`SetMinDecodeTPS`) | Per-request decode floor (tokens/s) used by admission; see [`../architecture/scheduling.md`](../architecture/scheduling.md). |
| `EIGENINFERENCE_DECODE_FLOOR_USE_FLEET_MEDIAN` | bool | `true` (*live*) | `coordinator/registry/scheduler.go` (`decodeFloorUseFleetMedian`) | Lets the per-request decode projection fall back to the fleet-median solo rate before the static benchmark. |
| `EIGENINFERENCE_SERVABILITY_GATE` | bool | `true` (*live*) | `coordinator/cmd/coordinator/main.go`; `coordinator/api/servability_gate.go` (`servabilityGateEnabled`) | Early 429 for requests whose prompt + `max_tokens` fit no provider; only an explicit `false` disables it. |
| `EIGENINFERENCE_LONG_PROMPT_TOKENS` | integer > 0 | unset (preference off) | `coordinator/cmd/coordinator/main.go` (`SetLongPromptThreshold`) | Prompts above this size prefer the fastest provider tier. |
| `EIGENINFERENCE_LONG_PROMPT_PREFILL_WEIGHT` | float (values below 1 clamp to neutral) | `2.0` | `coordinator/cmd/coordinator/main.go` (`SetLongPromptPrefillWeight`) | Prefill weight applied to long prompts; read only when the threshold is set. |
| `EIGENINFERENCE_PREFILL_DECODE_RATIO` | float > 0 | `12.0` | `coordinator/cmd/coordinator/main.go`; `coordinator/registry/scheduler.go` (`SetPrefillToDecodeRatio`) | Prefill-to-decode speed ratio in the TTFT estimate. |
| `EIGENINFERENCE_PROMPT_CALIBRATION` | `family:factor,…` (factors ≥ 1.0) | built-in table (`gpt-oss:1.3`) | `coordinator/api/prompt_calibration.go` (`SetPromptContextCalibrationFromEnv`) | Replaces the per-family prompt-token calibration used by the context gate. |
| `EIGENINFERENCE_MODEL_FIRST_CONTENT_BASES` | `model=upstream_ms,…` (`0`/`off` removes) | built-in table | `coordinator/modelpolicy/first_content_deadline.go` (`SetFirstContentBasesFromEnv`) | Overrides exact-model first-content deadline bases. |
| `EIGENINFERENCE_HEALTH_EJECTION` | `off`/`0`/`false`/`no` disables | on | `coordinator/registry/health_ejection_switch.go` (`healthEjectionSwitch`, parsed once at package init); `coordinator/registry/health_ejection.go` (`healthEjectionEnabled`) | Kill switch for provider health ejection; see [`../architecture/routing.md`](../architecture/routing.md). |
| `EIGENINFERENCE_DISABLE_CLIENT_ERROR_STOP` | bool | `false` | `coordinator/cmd/coordinator/main.go` (`SetDisableClientErrorStop`) | Lets deterministic provider 4xx errors fail over instead of stopping the dispatch ladder. |

TTFT admission and dispatch termination:

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `EIGENINFERENCE_TTFT_HARD_REJECT` | `true` | `false` (soft preference) | `coordinator/cmd/coordinator/main.go` (`SetTTFTHardReject`) | Restores the legacy 429 when the best estimated TTFT exceeds the model deadline. |
| `EIGENINFERENCE_TTFT_LIVE_DEADLINE_BASE_MS` | 1000–120000 | `5000` (production pins `9000`) | `coordinator/cmd/coordinator/main.go` (`validateTTFTDeadlineBaseMs`) | Live first-content deadline base (`FirstContentDeadlineBase`, plus 1 ms per prompt token); exact-model policy may only tighten it. |
| `EIGENINFERENCE_TTFT_DEADLINE_BASE_MS` | 1000–120000 | `10000` | `coordinator/cmd/coordinator/main.go`; `coordinator/registry/ttft_shadow.go` | Deadline base for shadow TTFT evaluation. |
| `EIGENINFERENCE_TTFT_OCCUPANCY_ALPHA` | float 0–1e6 | `0` (term off) | `coordinator/cmd/coordinator/main.go` (`validateTTFTOccupancyAlpha`) | Weight of the occupancy term in the TTFT estimate. |
| `EIGENINFERENCE_TTFT_ADMISSION_MODE` | `off`, `shadow`, `enforce` | `off` | `coordinator/cmd/coordinator/main.go`; `coordinator/registry/ttft_shadow.go` (`ParseTTFTAdmissionMode`) | Shadow evaluation of TTFT admission that emits `routing.ttft_admission` metrics without changing decisions; `enforce` currently behaves like `shadow`. |
| `EIGENINFERENCE_TTFT_CALIBRATION` | `off`/`false`/`0` disables | `on` (*live*) | `coordinator/registry/ttft_calibration.go` (`ttftCalibrationEnabled`) | Per-model TTFT calibration from observed samples; off makes the apply path return ratio 1.0. |
| `EIGENINFERENCE_TTFT_TERMINAL_REJECT` | `0`/`false`/`no`/`off` disables | `true` (*live*) | `coordinator/api/dispatch.go` (`ttftTerminalRejectEnabled`) | A TTFT-too-slow rejection ends the dispatch ladder on any attempt. |
| `EIGENINFERENCE_JINJA_TERMINAL_REJECT` | `0`/`false`/`no`/`off` disables | `true` (*live*) | `coordinator/api/dispatch.go` (`jinjaTerminalRejectEnabled`) | A chat-template render failure ends the ladder with one 422 instead of failing over. |

Queue and cold dispatch:

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `EIGENINFERENCE_QUEUE_MAX_DEPTH` | integer ≥ 1 | `32` | `coordinator/registry/queue.go` (`NewRequestQueueFromEnv`) | Per-model queue depth before 429. |
| `EIGENINFERENCE_QUEUE_MAX_WAIT` | Go duration > 0 | `120s` | `coordinator/registry/queue.go` (`NewRequestQueueFromEnv`) | Maximum time a request waits in the queue. |
| `EIGENINFERENCE_QUEUE_BEFORE_SHED` | `0`/`false`/`no`/`off` disables | `true` (*live*) | `coordinator/api/cold_dispatch.go` (`queueBeforeShedEnabled`) | Queue `machine_busy` preflight rejections instead of returning 429 immediately. |
| `EIGENINFERENCE_COLD_DISPATCH` | `0`/`false`/`no`/`off` disables | `true` (*live*) | `coordinator/api/cold_dispatch.go` (`coldDispatchEnabled`) | Spill `no_provider` requests into the queue when an idle on-disk provider can be warmed, and kick the load. |

Capacity breakers:

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `EIGENINFERENCE_BUDGET_CLAMP` | bool | `true` | `coordinator/registry/budget_clamp.go` | Clamp admission to a provider whose reported token budget is stale after a capacity 503. |
| `EIGENINFERENCE_BUDGET_CLAMP_TTL_SECONDS` | seconds | `300` | `coordinator/registry/budget_clamp.go` | Fail-open bound on how long a clamp can hold. |
| `EIGENINFERENCE_CAPACITY_COOLDOWN_THRESHOLD` | integer (`0` disables) | `5` | `coordinator/registry/capacity_cooldown.go` | Consecutive capacity rejects before a (provider, model) pair is cooled down. |
| `EIGENINFERENCE_CAPACITY_COOLDOWN_WINDOW_SECONDS` | seconds | `60` | `coordinator/registry/capacity_cooldown.go` | Window in which rejects count toward the threshold. |
| `EIGENINFERENCE_CAPACITY_COOLDOWN_TTL_SECONDS` | seconds | `120` | `coordinator/registry/capacity_cooldown.go` | Initial cooldown; doubles on each failed probe. |
| `EIGENINFERENCE_CAPACITY_COOLDOWN_MAX_TTL_SECONDS` | seconds | `600` | `coordinator/registry/capacity_cooldown.go` | Ceiling of the exponential cooldown. |
| `EIGENINFERENCE_CAPACITY_RATE_PENALTY_MS` | milliseconds (≤ 0 disables) | `15000` | `coordinator/registry/capacity_rate.go` | Scores a penalty proportional to a provider's recent capacity-reject rate. |

Reservation commit lock:

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `EIGENINFERENCE_RESERVE_COMMIT_MODE` | `shared`, `global` (trimmed, case-insensitive; any other value is treated as `shared` and logged as unknown) | `shared` | `coordinator/registry/gate_commit_mode.go` (`loadReserveCommitMode`, `parseReserveCommitMode`); read once at `registry.New` | How the reservation commit (`commitProviderReservation`, `ReserveNextFromPlan`) holds the registry lock. `shared` commits under `r.mu.RLock` plus the winner's `p.mu`; `global` is the kill switch that restores the fleet-wide `r.mu.Lock()` commit serialization. The fault-tracker recorders stay on their per-identity gates in both modes; see [`../architecture/routing.md`](../architecture/routing.md). |

Quality concurrency cap:

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `EIGENINFERENCE_QUALITY_CONCURRENCY_CAP` | bool | `true` | `coordinator/registry/config.go` (`ReadConfig`) | Per-provider admission cap derived from each model's quality concurrency instead of the flat cap. |
| `EIGENINFERENCE_QUALITY_CONCURRENCY_OVERCOMMIT` | float ≥ 0 | `1.2` (`defaultQualityCapOvercommit`; the `2.0` fallback in `ReadConfig` is replaced when the variable is unset) | `coordinator/registry/config.go` (`ReadConfig`); `coordinator/registry/concurrency_cap.go` (`SetQualityConcurrencyCap`) | Multiplier on the strict decode-floor batch. |
| `EIGENINFERENCE_QUALITY_CONCURRENCY_OVERCOMMIT_BY_MODEL` | `model=factor,…` | unset | `coordinator/registry/concurrency_cap.go` (`SetQualityConcurrencyCap`) | Per-model overcommit overrides. |
| `EIGENINFERENCE_QUALITY_CAP_PER_MODEL_TPS` | bool | `true` | `coordinator/registry/concurrency_cap.go` | Use per-model solo decode rates (not the provider-level rate) for the cap. |
| `EIGENINFERENCE_QUALITY_CAP_SOLO_MIN_SAMPLES` | integer | `5` | `coordinator/registry/concurrency_cap.go` | Solo samples required before a per-model median is trusted. |
| `EIGENINFERENCE_MODEL_SOLO_TPS_SEED` | `model[@chip-class]=tok/s,…` | unset | `coordinator/registry/concurrency_cap.go` (`soloTPSSeedForClass`) | Cold-start decode-rate seed until solo samples accumulate. |

#### Warm pool

All read once in `ReadConfig` (`coordinator/registry/config.go`); the controller
they tune is explained in
[scheduling.md → Warm-pool controller](../architecture/scheduling.md#warm-pool-controller):

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `EIGENINFERENCE_WARM_POOL_ENABLED` | bool | `true` | `coordinator/registry/config.go` | Runs the warm-pool controller (`StartWarmPoolController`). |
| `EIGENINFERENCE_WARM_POOL_OBSERVE_ONLY` | bool | `false` | `coordinator/registry/config.go` | Compute targets and metrics without issuing loads. |
| `EIGENINFERENCE_WARM_POOL_INTERVAL` | Go duration > 0 | `10s` | `coordinator/registry/config.go` | Controller tick. |
| `EIGENINFERENCE_WARM_POOL_MIN_DWELL` | Go duration | `5m` | `coordinator/registry/config.go` | Minimum time a model stays warm before it may be unloaded. |
| `EIGENINFERENCE_WARM_POOL_QUEUE_AGE_THRESHOLD` | Go duration | `0` | `coordinator/registry/config.go` | Queue age that counts as pressure. |
| `EIGENINFERENCE_WARM_POOL_CAPACITY_REJECT_THRESHOLD` | integer ≥ 1 | `1` | `coordinator/registry/config.go` | Capacity rejects per tick that count as pressure. |
| `EIGENINFERENCE_WARM_POOL_WARM_SATURATION_THRESHOLD` | float 0–1 | `0.8` | `coordinator/registry/config.go` | Warm-slot utilisation that counts as pressure. |
| `EIGENINFERENCE_WARM_POOL_TTFT_MISS_THRESHOLD` | integer ≥ 1 | `1` | `coordinator/registry/config.go` | TTFT misses per tick that count as pressure. |
| `EIGENINFERENCE_WARM_POOL_SPECULATIVE_START_THRESHOLD` | integer ≥ 1 | `2` | `coordinator/registry/config.go` | Speculative dispatch starts per tick that count as pressure. |
| `EIGENINFERENCE_WARM_POOL_SPECULATIVE_WIN_THRESHOLD` | integer ≥ 1 | `1` | `coordinator/registry/config.go` | Speculative wins per tick that count as pressure. |
| `EIGENINFERENCE_WARM_POOL_COLD_DISPATCH_THRESHOLD` | integer ≥ 1 | `1` | `coordinator/registry/config.go` | Cold dispatches per tick that count as pressure. |
| `EIGENINFERENCE_WARM_POOL_LOAD_DURATION_THRESHOLD` | Go duration | `20s` | `coordinator/registry/config.go` | Load duration above which a load is counted as slow. |
| `EIGENINFERENCE_WARM_POOL_DECODE_FLOOR_TPS` | float (≤ 0 disables) | `15` | `coordinator/registry/config.go` | Per-request decode floor used to derive quality concurrency for the target. |
| `EIGENINFERENCE_WARM_POOL_BURST_BUFFER` | integer ≥ 0 | `1` | `coordinator/registry/config.go` | Spare warm providers added to the demand-derived target. |
| `EIGENINFERENCE_WARM_POOL_FALLBACK_QUALITY_CONCURRENCY` | integer ≥ 1 | `4` | `coordinator/registry/config.go` | Per-provider concurrency assumed when rates are unknown. |
| `EIGENINFERENCE_WARM_POOL_ASSUMED_PROMPT_TOKENS` | integer ≥ 0 | `512` | `coordinator/registry/config.go` | Representative prompt size for the service-time estimate. |
| `EIGENINFERENCE_WARM_POOL_ASSUMED_COMPLETION_TOKENS` | integer ≥ 0 | `256` | `coordinator/registry/config.go` | Representative completion size for the service-time estimate. |
| `EIGENINFERENCE_WARM_POOL_MIN_WARM` | `model=count,…` | unset | `coordinator/registry/config.go` (`envModelIntMap`) | Operator floor of warm providers per concrete model id. |
| `EIGENINFERENCE_WARM_POOL_MAX_LOADS_PER_TICK` | integer ≥ 0 (`0` = observe) | `4` | `coordinator/registry/config.go` | Baseline load burst per tick. |
| `EIGENINFERENCE_WARM_POOL_MAX_LOADS_PER_TICK_CEILING` | integer ≥ 0 | `16` | `coordinator/registry/config.go` | Hard per-tick maximum after gap scaling. |
| `EIGENINFERENCE_WARM_POOL_RAMP_GAP_FRACTION` | float ≥ 0 | `0.5` | `coordinator/registry/config.go` | Scales the burst with the remaining target gap. |
| `EIGENINFERENCE_WARM_POOL_MAX_GLOBAL_PENDING_LOADS` | integer ≥ 0 | `16` | `coordinator/registry/config.go` | Fleet-wide cap on in-flight loads. |

Cache-aware routing (semantics in [`../architecture/cache-aware-routing.md`](../architecture/cache-aware-routing.md)). `refresh-env.sh` seeds absent keys from `deploy/gcp/prod/release-env-defaults` — production ships `MODE=off`, `PERCENT=1`, `MAX_PLAN_QPS=1` — and never overwrites a value an operator has set:

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `EIGENINFERENCE_CACHE_ROUTING_MODE` | `off`, `on` | `off` | `coordinator/registry/config.go` (`ReadConfig`, `CacheRoutingConfig.Check`) | Enables provider-confirmed cache routing; any other value refuses startup. |
| `EIGENINFERENCE_CACHE_ROUTING_PERCENT` | float (0, 100] | `100` | `coordinator/registry/config.go` (`envStrictFloat`) | Share of eligible requests that use cache routing; malformed values refuse startup. |
| `EIGENINFERENCE_CACHE_ROUTING_MAX_PLAN_QPS` | float 0–1,000,000 | `0` (unlimited) | `coordinator/registry/config.go` (`envStrictFloat`) | Rate limit on cache-plan computation. |
| `EIGENINFERENCE_CACHE_ROUTING_TTL` | Go duration ≥ 0 | `10m` | `coordinator/registry/config.go` | Lifetime of a cache-affinity holder. |
| `EIGENINFERENCE_CACHE_ROUTING_MAX_HOLDERS` | integer 1–32 | `4` | `coordinator/registry/config.go` | Maximum holders per affinity key. |
| `EIGENINFERENCE_CACHE_ROUTING_MAX_DISCOUNT_MS` | float 0–10000 | `1000` | `coordinator/registry/config.go` | Largest TTFT discount a cache hit may earn. |
| `EIGENINFERENCE_CACHE_ROUTING_MAX_COST_FRACTION` | float 0–1 | `0.35` | `coordinator/registry/config.go` | Cap on the cost fraction attributed to cache reuse. |
| `EIGENINFERENCE_CACHE_MASTER_KEY` | secret key material | unset; required when mode is `on` | `coordinator/registry/config.go` (`decodeCacheMasterKey`) | Keys the affinity digests so raw identity and prefix bytes are never stored. |

Rate limits and service-account admission (`coordinator/ratelimit/config.go`, `ReadConfig`):

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `EIGENINFERENCE_RATE_LIMIT_RPS`, `EIGENINFERENCE_RATE_LIMIT_BURST` | float, integer | `20`, `120` | `coordinator/ratelimit/config.go` | Per-account consumer request limiter. |
| `EIGENINFERENCE_RATE_LIMIT_ITPM`, `EIGENINFERENCE_RATE_LIMIT_ITPM_BURST` | tokens/min, tokens | `5000000`, `1000000` | `coordinator/ratelimit/config.go` | Per-account consumer input-token limiter (≤ 0 = unlimited). |
| `EIGENINFERENCE_RATE_LIMIT_OTPM`, `EIGENINFERENCE_RATE_LIMIT_OTPM_BURST` | tokens/min, tokens | `500000`, `64000` | `coordinator/ratelimit/config.go` | Per-account consumer output-token limiter. |
| `EIGENINFERENCE_FINANCIAL_RATE_LIMIT_RPS`, `EIGENINFERENCE_FINANCIAL_RATE_LIMIT_BURST` | float, integer | `0.2`, `3` | `coordinator/ratelimit/config.go` | Limiter on deposit, payout and other financial endpoints. |
| `EIGENINFERENCE_SERVICE_RATE_LIMIT_RPS`, `EIGENINFERENCE_SERVICE_RATE_LIMIT_BURST` | float (`0` = bypass), integer | `200`, `600` | `coordinator/ratelimit/config.go` | Request limiter for service accounts. |
| `EIGENINFERENCE_SERVICE_RATE_LIMIT_ITPM`, `EIGENINFERENCE_SERVICE_RATE_LIMIT_ITPM_BURST` | tokens/min, tokens | `50000000`, `5000000` | `coordinator/ratelimit/config.go` | Service-account input-token limiter. |
| `EIGENINFERENCE_SERVICE_RATE_LIMIT_OTPM`, `EIGENINFERENCE_SERVICE_RATE_LIMIT_OTPM_BURST` | tokens/min, tokens | `5000000`, `512000` | `coordinator/ratelimit/config.go` | Service-account output-token limiter. |
| `EIGENINFERENCE_SERVICE_EXPECTED_OUTPUT_ADMISSION_ENABLED` | bool | `false` | `coordinator/ratelimit/config.go`; `coordinator/cmd/coordinator/main.go` (`NewOutputAdmissionEstimator`) | Admit service requests against an expected output-token estimate. |
| `EIGENINFERENCE_SERVICE_EXPECTED_OUTPUT_ADMISSION_FRACTION` | float | `0.25` | `coordinator/ratelimit/config.go` | Fraction of `max_tokens` assumed as expected output. |
| `EIGENINFERENCE_SERVICE_EXPECTED_OUTPUT_ADMISSION_FLOOR`, `EIGENINFERENCE_SERVICE_EXPECTED_OUTPUT_ADMISSION_CEILING` | tokens | `512`, `8192` | `coordinator/ratelimit/config.go` | Bounds on the expected-output estimate. |

Throughput anomaly detector:

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `EIGENINFERENCE_THROUGHPUT_ANOMALY_INTERVAL` | Go duration > 0 | `5m` | `coordinator/api/throughput_anomaly.go` (`StartThroughputAnomalyDetector`) | Sweep cadence comparing observed decode rate to expectation per (model, chip class). |
| `EIGENINFERENCE_THROUGHPUT_ANOMALY_RATIO` | float > 0 | `0.35` | `coordinator/api/throughput_anomaly.go` (`throughputAnomalyConfigFromEnv`) | Observed/expected ratio below which a bucket is anomalous. |
| `EIGENINFERENCE_THROUGHPUT_ANOMALY_MIN_SAMPLES` | integer > 0 | `3` | `coordinator/api/throughput_anomaly.go` (`throughputAnomalyConfigFromEnv`) | Providers required in a bucket before it is judged. |
| `EIGENINFERENCE_THROUGHPUT_ANOMALY_EFFICIENCY` | float > 0 | `0.80` | `coordinator/api/throughput_anomaly.go` (`throughputAnomalyConfigFromEnv`) | Expected decode efficiency relative to the chip's theoretical rate. |

### Billing, Stripe and base rewards

Prices, the platform fee and the referral share live in [`../architecture/billing.md#invariants`](../architecture/billing.md#invariants); this table only names the switches.

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `EIGENINFERENCE_BILLING_MOCK` | `true` | `false` | `coordinator/billing/config.go` (`ReadConfig`); `coordinator/cmd/coordinator/main.go` | Bypasses Stripe with an instant-credit mock (dev only). |
| `EIGENINFERENCE_REFERRAL_SHARE_PCT` | integer percent | `20` | `coordinator/billing/config.go` (`ReadConfig`) | Share of the platform fee paid to a consumer's referrer. |
| `EIGENINFERENCE_STRIPE_SECRET_KEY` | secret | unset (deposits disabled) | `coordinator/billing/config.go` (`ReadConfig`) | Stripe API key for consumer deposits. |
| `EIGENINFERENCE_STRIPE_WEBHOOK_SECRET` | secret | unset | `coordinator/billing/config.go` (`ReadConfig`) | Verifies Checkout webhooks. |
| `EIGENINFERENCE_STRIPE_SUCCESS_URL`, `EIGENINFERENCE_STRIPE_CANCEL_URL` | URLs | unset | `coordinator/billing/config.go` (`ReadConfig`); `coordinator/billing/stripe.go` (`NewStripeProcessor`) | Checkout redirect targets. |
| `EIGENINFERENCE_STRIPE_CONNECT_WEBHOOK_SECRET` | secret | unset | `coordinator/billing/config.go` (`ReadConfig`) | Verifies Connect account webhooks (provider payouts). |
| `EIGENINFERENCE_STRIPE_CONNECT_COUNTRY` | ISO 3166-1 alpha-2 | `US` | `coordinator/billing/config.go` (`ReadConfig`) | Country for new Connect express accounts. |
| `EIGENINFERENCE_STRIPE_CONNECT_RETURN_URL`, `EIGENINFERENCE_STRIPE_CONNECT_REFRESH_URL` | URLs | unset | `coordinator/billing/config.go` (`ReadConfig`); `coordinator/api/stripe_payouts.go` | Connect onboarding redirect targets; caller-supplied URLs are validated against the configured return URL. |
| `EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_ENABLED` | bool | `true` in production release defaults; `false` otherwise | `coordinator/billing/config.go` (`ReadConfig`, `Check`); `deploy/gcp/prod/release-env-defaults` | Enables new international onboarding, quotes and withdrawals. Production refresh preserves an explicit `false` and requires the funding account and webhook secret before activation; runtime validation also requires the base `EIGENINFERENCE_STRIPE_SECRET_KEY` used for Connect. Reconciliation continues with configured credentials even when disabled. |
| `EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_FINANCIAL_ACCOUNT` | ID | unset | `coordinator/billing/config.go` (`Check`) | Funding financial account; required when enabled. |
| `EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_SECRET_KEY` | secret | falls back to `EIGENINFERENCE_STRIPE_SECRET_KEY` | `coordinator/billing/config.go` (`ReadConfig`) | Restricted API key override for Global Payouts; does not replace the required base Connect key. |
| `EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_WEBHOOK_SECRET` | secret | unset | `coordinator/api/global_payouts_reconcile.go` (`handleGlobalPayoutWebhook`) | Verifies the separate Global Payouts event destination; missing secret rejects all events. |
| `EIGENINFERENCE_SERVICE_RESERVATIONS_ENABLED` | bool | `false` | `coordinator/api/server_config.go` (`ReadServerConfig`) | Reserve balance up front for service-account requests. |
| `EIGENINFERENCE_BASE_REWARDS` | bool | `false` | `coordinator/api/server_config.go` (`ReadServerConfig`) | Turns on the hourly base-rewards settlement loop. |
| `EIGENINFERENCE_BASE_REWARDS_K` | float | `0` (additive base income; `1` = legacy max backstop) | `coordinator/api/server_config.go` (`ReadServerConfig`) | Reduction factor applied to earnings before the floor is paid. |
| `EIGENINFERENCE_BASE_REWARDS_POOL_MICRO` | integer µUSD | `9000000000` ($9,000 per month) | `coordinator/api/server_config.go` (`ReadServerConfig`) | Monthly cap on the base-rewards pool. |
| `EIGENINFERENCE_BASE_REWARDS_MIN_UPTIME` | float 0–1 | `0.90` | `coordinator/api/server_config.go` (`ReadServerConfig`) | Uptime fraction required to share in the pool. |
| `EIGENINFERENCE_BASE_REWARDS_ACCOUNT_CAP` | float 0–1 (`0` = per machine, no cap) | `0` | `coordinator/api/server_config.go` (`ReadServerConfig`) | Cap on one account's share of the pool. |

### Model registry, releases and R2/CDN

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `MODEL_REGISTRY_PUBLISHING_KEY` | secret | unset | `coordinator/api/model_registry_handlers.go` (`requirePublishingAPIKey`) | Bootstrap bearer token accepted (constant-time) for model-registry publishing in addition to admin keys; see [`../architecture/model-registry.md`](../architecture/model-registry.md). |
| `MODEL_REGISTRY_CDN_BASE_URL` | URL | unset (registry entries carry no CDN base) | `coordinator/api/model_registry_handlers.go` (`registryCDNBaseURL`) | Base URL providers download published model weights from. |
| `EIGENINFERENCE_R2_CDN_URL` | URL | unset | `coordinator/api/server_config.go` (`ReadServerConfig`); `coordinator/api/release_handlers.go` (`trustedReleaseArtifactURL`) | Public R2 bucket URL release binaries are pulled from; release registration is refused (503) until it is set, and every registered artifact URL must live under it. See [`../operations/release-policy-rollout.md`](../operations/release-policy-rollout.md). |

### Prompt sidecar and media fetch

Prompt sidecar (`coordinator/promptcontract/config.go`, `ReadSupervisorConfig`; every duration is an integer count of milliseconds; `Check` refuses startup on an out-of-range value when the sidecar is enabled). Semantics: [`../architecture/prompt-contract-sidecar.md`](../architecture/prompt-contract-sidecar.md).

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `EIGENINFERENCE_PROMPT_SIDECAR_ENABLED` | bool | `false` | `coordinator/promptcontract/config.go` | Starts the supervised prompt-contract sidecar and its artifact provisioner. |
| `EIGENINFERENCE_PROMPT_SIDECAR_BINARY` | executable path or name | `promptsidecar` | `coordinator/promptcontract/config.go` | Sidecar binary the supervisor spawns. |
| `EIGENINFERENCE_PROMPT_SIDECAR_SOCKET` | absolute path | `/run/darkbloom/promptsidecar.sock` (`DefaultSocketPath`) | `coordinator/promptcontract/config.go` | Unix socket the coordinator dials. |
| `EIGENINFERENCE_PROMPT_SIDECAR_ARTIFACT_ROOT` | absolute directory | `/mnt/disks/userdata/prompt-contracts` (`DefaultArtifactRoot`) | `coordinator/promptcontract/config.go` | Cache of downloaded contract artifacts. |
| `EIGENINFERENCE_PROMPT_SIDECAR_ARTIFACT_BASE_URL` | `https://` URL without query or credentials | `https://models.darkbloom.ai` | `coordinator/promptcontract/config.go` | Origin artifacts are downloaded from. |
| `EIGENINFERENCE_PROMPT_SIDECAR_ARTIFACT_TIMEOUT_MS` | ms | `120000` | `coordinator/promptcontract/config.go` | Per-artifact download timeout. |
| `EIGENINFERENCE_PROMPT_SIDECAR_PROVISION_WORKERS`, `EIGENINFERENCE_PROMPT_SIDECAR_PROVISION_MAX_MODELS` | integers, workers ≤ models | `2`, `128` | `coordinator/promptcontract/config.go`; `coordinator/promptcontract/provisioner.go` | Provisioning concurrency and the maximum number of models provisioned. |
| `EIGENINFERENCE_PROMPT_SIDECAR_HEADER_TIMEOUT_MS`, `EIGENINFERENCE_PROMPT_SIDECAR_TIMEOUT_MS`, `EIGENINFERENCE_PROMPT_SIDECAR_HEALTH_TIMEOUT_MS`, `EIGENINFERENCE_PROMPT_SIDECAR_PRELOAD_TIMEOUT_MS` | ms | `1000`, `1000`, `250`, `120000` | `coordinator/promptcontract/config.go`; `coordinator/promptcontract/client.go` | Client deadlines for reading a response header, a render call, a health probe and a preload. |
| `EIGENINFERENCE_PROMPT_SIDECAR_STARTUP_TIMEOUT_MS`, `EIGENINFERENCE_PROMPT_SIDECAR_HEALTH_INTERVAL_MS`, `EIGENINFERENCE_PROMPT_SIDECAR_HEALTH_FAILURE_THRESHOLD`, `EIGENINFERENCE_PROMPT_SIDECAR_SHUTDOWN_TIMEOUT_MS` | ms, ms, integer ≥ 2, ms | `120000`, `1000`, `5`, `2000` | `coordinator/promptcontract/config.go`; `coordinator/promptcontract/supervisor_defaults.go` (`applySupervisorDefaults`) | Supervisor readiness wait, probe cadence, consecutive failures before a restart, graceful-stop budget. |
| `EIGENINFERENCE_PROMPT_SIDECAR_RESTART_MIN_MS`, `EIGENINFERENCE_PROMPT_SIDECAR_RESTART_MAX_MS`, `EIGENINFERENCE_PROMPT_SIDECAR_RESTART_WINDOW_MS`, `EIGENINFERENCE_PROMPT_SIDECAR_RESTART_MAX_IN_WINDOW`, `EIGENINFERENCE_PROMPT_SIDECAR_RESTART_COOLDOWN_MS` | ms, ms, ms, integer, ms | `100`, `5000`, `60000`, `3`, `30000` | `coordinator/promptcontract/config.go` | Crash-loop backoff and circuit breaker. |
| `EIGENINFERENCE_PROMPT_SIDECAR_STDERR_MAX_BYTES` | bytes 1024–1048576 | `16384` | `coordinator/promptcontract/config.go` | Sidecar stderr retained per incarnation. |
| `EIGENINFERENCE_PROMPT_SIDECAR_MAX_BODY_BYTES`, `EIGENINFERENCE_PROMPT_SIDECAR_MAX_TOKENS` | bytes, tokens | `4194304` (`DefaultMaxRequestBytes`), `1048576` (`DefaultMaxTokens`) | `coordinator/promptcontract/config.go`; `coordinator/promptcontract/client.go` | Request-body and rendered-token ceilings handed to the sidecar. |
| `EIGENINFERENCE_PROMPT_SIDECAR_MAX_CONCURRENCY`, `EIGENINFERENCE_PROMPT_SIDECAR_MAX_CONNECTIONS`, `EIGENINFERENCE_PROMPT_SIDECAR_MAX_LOADED_CONTRACTS` | integers | `4`, `64`, `8` | `coordinator/promptcontract/config.go` | Sidecar-side concurrency, connection and loaded-contract limits. |
| `EIGENINFERENCE_PROMPT_SIDECAR_MEMORY_LIMIT_MIB` | MiB ≥ 256 | `1024` | `coordinator/promptcontract/config.go` | Memory ceiling applied to the sidecar process. |

Media fetch (`coordinator/mediafetch/config.go`, `ConfigFromEnv`; a set-but-unparseable value is recorded and fails startup in `Check`, so a mistyped kill switch cannot silently keep fetching):

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `EIGENINFERENCE_MEDIA_FETCH_ENABLED` | bool | `true` | `coordinator/mediafetch/config.go` | Lets the coordinator download `image_url`/`video_url` inputs and inline them as `data:` URIs before relaying; when off, requests carrying remote media are rejected. See [`../architecture/data-flow.md`](../architecture/data-flow.md). |
| `EIGENINFERENCE_MEDIA_FETCH_MAX_FILE_BYTES`, `EIGENINFERENCE_MEDIA_FETCH_MAX_TOTAL_BYTES` | bytes | `8388608` (8 MiB), `10485760` (10 MiB) | `coordinator/mediafetch/config.go` | Per-file and per-request raw download ceilings. |
| `EIGENINFERENCE_MEDIA_FETCH_TIMEOUT_MS`, `EIGENINFERENCE_MEDIA_FETCH_TOTAL_DEADLINE_MS` | ms | `15000`, `25000` | `coordinator/mediafetch/config.go` | Per-URL fetch timeout and whole-request resolution deadline. |
| `EIGENINFERENCE_MEDIA_FETCH_GLOBAL_CONCURRENCY` | integer | `32` | `coordinator/mediafetch/config.go` | Process-wide cap on in-flight fetches. |
| `EIGENINFERENCE_MEDIA_FETCH_MAX_IMAGE_MEGAPIXELS` | integer (`0` disables) | `100` | `coordinator/mediafetch/config.go` | Header-decoded pixel cap for fetched images. |
| `EIGENINFERENCE_MEDIA_FETCH_BLOCKLIST_DOMAINS` | comma-separated hostnames | unset | `coordinator/mediafetch/config.go` | Hosts that are never fetched. |
| `EIGENINFERENCE_MEDIA_FETCH_ALLOW_PRIVATE_IPS`, `EIGENINFERENCE_MEDIA_FETCH_ALLOW_NONSTANDARD_PORTS` | bool | `false`, `false` | `coordinator/mediafetch/config.go` | SSRF guards: allow loopback/private/link-local targets or ports other than 80/443 (tests only). |

### Telemetry, Datadog and profiling

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `DD_API_KEY` | secret | unset (no metric or log shipping) | `coordinator/datadog/datadog.go` (`ConfigFromEnv`); `coordinator/cmd/coordinator/main.go` | Enables the Datadog client (metrics over the HTTP API, Logs API forwarding) and the APM tracer; see [`../architecture/telemetry.md`](../architecture/telemetry.md). |
| `DD_AGENT_HOST` | hostname | unset | `coordinator/cmd/coordinator/main.go` | Also starts the APM tracer and trace-context log handler when set (agent-based deployments without an API key). |
| `DD_SITE` | Datadog site | `datadoghq.com` | `coordinator/datadog/datadog.go` (`ConfigFromEnv`) | Intake endpoint. |
| `DD_ENV`, `DD_SERVICE` | strings | `production`, `d-inference-coordinator` | `coordinator/datadog/datadog.go` (`ConfigFromEnv`) | `env:` and `service:` tags on every series, log and trace. |
| `DD_DOGSTATSD_URL` | `host:port` | `localhost:8125` | `coordinator/datadog/datadog.go` (`ConfigFromEnv`) | DogStatsD agent address. |
| `DD_HOSTNAME` | hostname | the `DD_SERVICE` value | `coordinator/datadog/datadog.go` (`NewClient`) | `host` attribute on series shipped over the HTTP metrics API. |
| `EIGENINFERENCE_PROFILER` | `off` disables | `on` | `coordinator/api/profiler.go` (`newProfilerFromEnv`) | Kill switch for the per-request system profiler; see [`../architecture/system-profiler.md`](../architecture/system-profiler.md). |
| `EIGENINFERENCE_PROFILE_SAMPLE_RATE` | float 0–1 | `0.1` | `coordinator/api/profiler.go` (`newProfilerFromEnv`) | Fraction of successful requests the profiler samples; slow, failed and retried requests are always recorded. |

## Provider CLI (`darkbloom`)

Parsing convention: affirmative values are `1`/`true`/`yes`/`on`, negative values `0`/`false`/`no`/`off`, case-insensitive. Only the variables named in the LaunchAgent allow-list above reach an installed daemon; everything else applies to `darkbloom start --foreground` and to the benchmark and test binaries.

### Operator-facing: daemon, paths, updates

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `DARKBLOOM_NO_UPDATE_CHECK` | any value | unset | `provider-swift/Sources/darkbloom/Darkbloom.swift`; `provider-swift/Sources/darkbloom/StartCommand+Modes.swift`; `provider-swift/Sources/darkbloom/WatchdogCommand.swift`; `provider-swift/Sources/ProviderCore/ProviderLoop+AutoUpdate.swift`; forwarded by `provider-swift/Sources/ProviderCore/Service/WatchdogAgent.swift` | Skips the startup version banner, the in-daemon auto-update loop, the start-mode check and the watchdog's update check; `scripts/install.sh` sets it for the runtime smoke test. |
| `DARKBLOOM_AUTH_TOKEN_PATH` | file path | `~/.darkbloom/auth_token` | `provider-swift/Sources/ProviderCore/Auth/DeviceAuth.swift` | Where the device-auth token is stored. |
| `DARKBLOOM_LOCAL_DIR` | directory | `~/.darkbloom` | `provider-swift/Sources/ProviderCore/Server/LocalEndpoint.swift` | Directory for `local_token` and `local.json` (direct mode). |
| `DARKBLOOM_STATE_FILE` | file path | `~/.darkbloom/daemon-state.json` | `provider-swift/Sources/ProviderCore/Service/DaemonStateFile.swift` | Daemon state snapshot read by `status`, `doctor` and the watchdog. |
| `DARKBLOOM_LOADED_MODELS_FILE` | file path | `~/.darkbloom/loaded-models.json` | `provider-swift/Sources/ProviderCore/Service/LoadedModelsStore.swift` | Warm-model journal. |
| `DARKBLOOM_PID_FILE` | file path | `~/.darkbloom/provider.pid` | `provider-swift/Sources/ProviderCore/Service/ProcessLifecycle.swift` | Daemon PID file. |
| `DARKBLOOM_WATCHDOG_STATE` | file path | `~/.darkbloom/watchdog-state.json` | `provider-swift/Sources/ProviderCore/Service/WatchdogState.swift` | Watchdog arm/disarm state. |
| `DARKBLOOM_KV_BACKEND_GUARD` | absolute file path | `~/.darkbloom/kv-backend-guard.json` | `provider-swift/Sources/ProviderCore/Service/KVBackendGuard.swift` | Crash-loop guard record; on the LaunchAgent allow-list so the watchdog and daemon share one file. |
| `DARKBLOOM_R2_CDN_URL` | URL | `https://models.darkbloom.ai` | `provider-swift/Sources/ProviderCore/Models/ModelDownloader.swift` | Mirror model weights are downloaded from. |
| `DARKBLOOM_KEYCHAIN_ACCESS_GROUP` | access group | `SLDQ2GJ6TL.io.darkbloom.provider` | `provider-swift/Sources/ProviderCore/Security/PersistentEnclaveKey.swift` | Keychain access group for the Secure Enclave key items. |
| `DARKBLOOM_MLX_RESOURCE_DEBUG` | `0` quiets | unset (telemetry on) | forwarded only, `provider-swift/Sources/ProviderCore/Service/LaunchAgent.swift` | MLX resource telemetry switch consumed by `mlx-swift-lm`. |

### Engine and scheduler

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `DARKBLOOM_CBV2_PAGED_KV` | `0` forces contiguous | unset (policy decides) | `provider-swift/Sources/ProviderCore/Inference/EngineV2KVBackendPolicy.swift` | Kill switch for paged KV; beats the `provider.toml` setting. |
| `DARKBLOOM_CBV2_PAGED_KV_DTYPE` | `float16`, `float32` | `float16` | `provider-swift/Sources/ProviderCore/Inference/EngineV2Factory+Production.swift` | Paged-KV storage dtype; any other value throws at engine build. |
| `DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE` | tokens | engine default | `provider-swift/Sources/ProviderCore/Inference/EngineV2Factory+Production.swift` | Solo-prefill stripe size. |
| `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS` | integer (`0` = unlimited) | `1` | `provider-swift/Sources/ProviderCore/Inference/EngineV2Factory+Production.swift` | Maximum concurrent partial prefills. |
| `DARKBLOOM_CBV2_LEGACY_REQUEST_TIMEOUT` | affirmative | off | `provider-swift/Sources/ProviderCore/Inference/EngineV2Factory+Production.swift` | Restores the legacy per-request timeout. |
| `DARKBLOOM_CBV2_MTP` | negative disables | unset (beta flag decides) | `provider-swift/Sources/ProviderCore/SpecDec/SpecDecArtifactFunnel.swift`; `provider-swift/Sources/ProviderCore/Config/BetaFeatures.swift` | Kill switch for MTP speculation; beats the `provider.toml` beta flag. See [`../provider/beta-features.md`](../provider/beta-features.md). |
| `DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS` | integer | policy default | `provider-swift/Sources/ProviderCore/Inference/MTPAutomaticVerificationPolicy.swift` | Tighten-only cap on rectangular MTP verification tokens. |
| `DARKBLOOM_MTP_VERIFICATION_MODE` | `rectangular`, `serial`, `serial_target`, `automatic` | `automatic` | `provider-swift/Sources/ProviderBenchmark/MTPProductionSession.swift` | MTP verification strategy (benchmark session). |
| `DARKBLOOM_PREFILL_DEADLINE_MODE` | `off`, `enforce` | `off` | `provider-swift/Sources/ProviderCore/Inference/PrefillDeadlineMode.swift` | Prefill-deadline admission on the provider. |
| `DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL` | integer layers | projected from `provider.toml` (`18`) | `provider-swift/Sources/ProviderCore/Config/GemmaOptimizationEnvironment.swift` | Gemma-4 prefill chunk-eval layers; the provider sets it for the engine, `scripts/install.sh` sets `18` for the smoke test. |
| `DARKBLOOM_ENGINE_V2_VLM_PARITY_CHECK` | `0` skips | on | `provider-swift/Sources/ProviderCore/Inference/EngineV2VLMTextExtraction.swift` | VLM text-extraction parity check. |

### Memory and media budgets

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `DARKBLOOM_MLX_CACHE_LIMIT_GB` | GiB (floor 1) | `8` | `provider-swift/Sources/ProviderCore/Inference/MLXMemoryGuard.swift` | MLX buffer-cache limit. |
| `DARKBLOOM_MLX_MEMORY_RESERVE_GB` | GiB | `provider.toml` `memory_reserve_gb` | `provider-swift/Sources/ProviderCore/Inference/MLXMemoryGuard.swift` | Overrides the whole-machine memory reserve. |
| `DARKBLOOM_MEM_CAP_FRACTION` | fraction | `0.90` | `provider-swift/Sources/ProviderCore/Inference/UnifiedMemoryCap.swift` | Share of unified memory the engine may address. |
| `DARKBLOOM_ACTIVATION_RESERVE_GB` | GiB (raise-only) | `5.5` | `provider-swift/Sources/ProviderCore/Inference/UnifiedMemoryCap.swift` | Activation headroom kept out of the weight budget. |
| `DARKBLOOM_VISION_MAX_TOWER_PATCHES` | integer (lower-only) | model default | `provider-swift/Sources/ProviderCore/Inference/VisionTowerBudget.swift` | Caps vision-tower patches. |
| `DARKBLOOM_MAX_IMAGE_MEGAPIXELS`, `DARKBLOOM_MAX_REQUEST_IMAGE_MEGAPIXELS` | megapixels | `100`, `384` | `provider-swift/Sources/ProviderCore/Inference/MediaIngest.swift` | Per-image and per-request pixel caps. |
| `DARKBLOOM_MAX_MEDIA_MIB` | MiB | `25` | `provider-swift/Sources/ProviderCore/Inference/MediaIngest.swift` | Per-request media bytes. |
| `DARKBLOOM_MAX_VIDEO_SECONDS` | seconds | `600` | `provider-swift/Sources/ProviderCore/Inference/MediaIngest.swift` | Per-video duration cap. |
| `DARKBLOOM_MAX_IMAGES_PER_REQUEST`, `DARKBLOOM_MAX_VIDEOS_PER_REQUEST` | integers | `16`, `8` | `provider-swift/Sources/ProviderCore/Inference/MediaIngest.swift` | Attachment count caps. |
| `DARKBLOOM_MAX_REQUEST_VIDEO_FRAME_MEGAPIXELS` | megapixels | `384` | `provider-swift/Sources/ProviderCore/Inference/MediaIngest.swift` | Per-request decoded video-frame pixel cap. |

### SSD prefix cache

Internals and file format: [`ssd-kv-cache.md`](ssd-kv-cache.md).

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `DARKBLOOM_PREFIX_CACHE` | non-affirmative disables | on | `provider-swift/Sources/ProviderCore/Inference/PrefixCachePolicy.swift` | Master switch for the SSD prefix cache. |
| `DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS` | seconds (`0` off) | `120` | `provider-swift/Sources/ProviderCore/Inference/PrefixCachePolicy.swift` | Cadence of the cache stats log line. |
| `DARKBLOOM_PREFIX_CACHE_DISK_GB` | GiB | `20`, clamped to half the free space | `provider-swift/Sources/ProviderCore/Inference/PrefixCachePolicy.swift` | Box-wide on-disk budget. |
| `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL` | affirmative | off | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCacheFactory.swift` | Allows a tmp-backed cache (tests and stress runs). |
| `DARKBLOOM_PREFIX_CACHE_TEST_ROOT` | directory | unset | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCacheFactory.swift` | Test override of the cache root. |
| `DARKBLOOM_PREFIX_CACHE_SSD_TTL_SECONDS` | seconds ≤ 900 | `900` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` | Entry time-to-live. |
| `DARKBLOOM_PREFIX_CACHE_SSD_MAX_WRITE_GB_PER_DAY` | GB/day (`0` unlimited) | `150` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` | Write-endurance budget. |
| `DARKBLOOM_PREFIX_CACHE_SSD_MIN_EFFECTIVE_TOKENS` | tokens | `1024` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` | Smallest prefix worth persisting. |
| `DARKBLOOM_PREFIX_CACHE_SSD_WINDOW_SIDECAR` | affirmative | off | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` | Persists the sliding-window sidecar. |
| `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MB`, `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MS` | MiB, ms | `1024`, `1000` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` | Staging buffer size and deadline. |
| `DARKBLOOM_PREFIX_CACHE_SSD_STRICT_FSYNC` | affirmative | off | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` | `fsync` after every write. |

### Benchmark, harness and tests

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `DARKBLOOM_ARRIVAL_TOLERANCE_MS` | ms | harness default | `provider-swift/Sources/ProviderBenchmark/ArrivalInvarianceBenchmark.swift` | Arrival-invariance tolerance. |
| `DARKBLOOM_QWEN_FCFS_LIVE` | `1` | unset | `provider-swift/Sources/ProviderBenchmark/SchedulerPrefillDecisionCLI.swift` | Enables the live Qwen FCFS harness. |
| `DARKBLOOM_QWEN_FCFS_MODEL_PATH`, `DARKBLOOM_QWEN_FCFS_MODEL_ID`, `DARKBLOOM_QWEN_FCFS_EXPECTED_MODEL_HASH`, `DARKBLOOM_QWEN_FCFS_SOURCE_SHA`, `DARKBLOOM_QWEN_FCFS_ITERATIONS`, `DARKBLOOM_QWEN_FCFS_KV_BACKEND`, `DARKBLOOM_QWEN_FCFS_OUTPUT` | strings | unset | `provider-swift/Sources/ProviderBenchmark/SchedulerPrefillDecisionCLI.swift` | Harness inputs. |
| `DARKBLOOM_QWEN_MTP_SERIAL` | affirmative | off | `provider-swift/Tests/ProviderCoreTests/Qwen38ProductionCanarySupport.swift` (tests only) | Forces serial MTP verification in the Qwen canary. |

### Retired (parsed only to warn)

`provider-swift/Sources/ProviderCore/Inference/EngineV2Config.swift` recognises these and logs a warning; they have no effect: `DARKBLOOM_ENGINE_V2`, `DARKBLOOM_ENGINE_V2_MODELS`, `DARKBLOOM_COMPILED_DECODE`, `DARKBLOOM_GEMMA_B1_FAST_PATH`, `DARKBLOOM_B1_GREEDY_FAST_PATH`, `DARKBLOOM_KV_GPTOSS_KERNEL`, `DARKBLOOM_ADAPTIVE_PREFILL_ALLOW_8192`, `DARKBLOOM_KV_CAPTURE_MAX_INFLIGHT`, `DARKBLOOM_PREFIX_CACHE_MIN_PERSIST_TOKENS`. Six more names appear only in comments because `mlx-swift-lm` reads them, not the provider (`DARKBLOOM_CBV2_ATTN_QUERY_BLOCK`, `DARKBLOOM_CBV2_PAGED_PTOK_TARGET`, `DARKBLOOM_CBV2_COMPILED`, `DARKBLOOM_GEMMA4_PREFILL_TAIL_ROWS`, `DARKBLOOM_GEMMA4_PREFILL_LAST_QUERY`, `DARKBLOOM_CBV2_MIXED_PREFILL_CAP`); none is on the LaunchAgent allow-list, so they only apply under `start --foreground`.

### Non-`DARKBLOOM_` variables the provider honours

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `MLX_GEMMA4_FUSED_WEIGHTED_UNSORT` | flag | set by the provider | `provider-swift/Sources/ProviderCore/Config/GemmaOptimizationEnvironment.swift`; `provider-swift/Sources/darkbloom/ServeRuntimePreparer.swift` | Provider-set MLX fused-unsort switch for Gemma 4. |
| `MLX_GATHER_QMM_EXPERT_SLICES` | `1` (drain) or config-backed `0`/`trust` | `trust` | `provider-swift/Sources/ProviderCore/Config/GemmaOptimizationEnvironment.swift`; `provider-swift/Sources/ProviderCore/Inference/PackagedRuntimeSmoke.swift` | Expert-slice route mode; only an exact `1` is persisted into the LaunchAgent plist. |
| `SUDO_UID` | uid | set by `sudo` | `provider-swift/Sources/darkbloom/Fan/FanServiceManager.swift` | Resolves the invoking user when `darkbloom fan` runs under `sudo`. |
| `GITHUB_SHA` | commit | unset | `provider-swift/Sources/ProviderBenchmark/SchedulerPrefillDecisionCLI.swift` | Fallback source SHA in benchmark reports. |
| `DYLD_INSERT_LIBRARIES`, `DYLD_LIBRARY_PATH`, `DYLD_FRAMEWORK_PATH`, `LD_PRELOAD`, `MallocStackLogging`, `MallocStackLoggingNoCompact`, `MallocScribble`, `MallocGuardEdges`, `MallocLogFile`, `MallocErrorAbort`, `NSZombieEnabled`, `OBJC_DEBUG_POOL_ALLOCATION`, `CFNETWORK_DIAGNOSTICS` | — | — | `provider-swift/Sources/ProviderCore/Security/EnvironmentScrubber.swift` | Removed from the daemon's environment at start; reported as the `env_scrubbed` capability. |

`scripts/install.sh` additionally reads `COORD_URL` (substituted by the coordinator when it serves `/install.sh`; required when the script is run from source), `HOME` (install root `$HOME/.darkbloom`), `TMPDIR` (enrollment-profile temp dir only) and the two code-signing requirement constants `DARKBLOOM_DESIGNATED_REQUIREMENT` and `DARKBLOOM_FAN_HELPER_REQUIREMENT`. See [`../provider/installation.md`](../provider/installation.md).

## console-ui

All variables are inlined at build time.

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `NEXT_PUBLIC_COORDINATOR_URL` | URL | `https://api.darkbloom.dev` | `console-ui/src/lib/server/coordinator.ts` (`coordinatorUrl`); `console-ui/src/lib/coordinator-url.ts` (`PUBLIC_COORDINATOR_URL`) | Upstream coordinator for every proxy route and for client-side display; a browser can override it via the `darkbloom_coordinator_url` localStorage key. |
| `NEXT_PUBLIC_PRIVY_APP_ID` | Privy app id | `""` | `console-ui/src/components/providers/PrivyClientProvider.tsx` | Unset or the literal `placeholder` selects mock auth (always authenticated, no token); otherwise the real Privy provider. |
| `NEXT_PUBLIC_GA_MEASUREMENT_ID` | `G-…` | `G-M65PNVW5TE` (only `undefined` falls back; set `""` to disable) | `console-ui/src/lib/google-analytics.ts` | Google Analytics page-view tracking after consent. |
| `NEXT_PUBLIC_DD_APPLICATION_ID`, `NEXT_PUBLIC_DD_CLIENT_TOKEN` | Datadog RUM credentials | unset (RUM off) | `console-ui/src/components/DatadogRUM.tsx` | Both must be set for RUM to initialise. |
| `NEXT_PUBLIC_DD_SITE`, `NEXT_PUBLIC_DD_ENV`, `NEXT_PUBLIC_APP_VERSION` | strings | `datadoghq.com`, `production`, `dev` | `console-ui/src/components/DatadogRUM.tsx` | RUM site, env and version tags. |
| `NODE_ENV` | set by Next | — | `console-ui/src/app/stats/model-brand.ts` | Suppresses unknown-brand console warnings in production. |
| `SHARED_BUDGET_KB`, `ROUTE_BUDGET_KB` | KiB | `450`, `650` | `console-ui/scripts/analyze-bundle.mjs` | Bundle-size budgets for the build analysis script (not runtime). |

## admin-ui

Server-only runtime variables. See [`../architecture/components/admin-ui.md`](../architecture/components/admin-ui.md).

| Variable | Values / type | Default | Read in | Effect |
|---|---|---|---|---|
| `ADMIN_DB_URL` | Postgres DSN (secret) | required; pool creation throws | `admin-ui/src/lib/db.ts` | Read-only replica connection; `sslmode`/`ssl` query parameters are stripped and SSL is configured programmatically. |
| `ADMIN_DB_SSL_NO_VERIFY` | `true` | unset (certificates verified) | `admin-ui/src/lib/db.ts` | Accepts self-signed replica certificates. |
| `ADMIN_BASIC_USER`, `ADMIN_BASIC_PASS` | credentials (secret) | required; auth fails closed | `admin-ui/src/lib/auth.ts`, enforced by `admin-ui/src/proxy.ts` | HTTP Basic credentials compared as constant-time SHA-256 digests. |
| `NODE_ENV` | set by Next | — | `admin-ui/src/lib/db.ts` | Outside `production` the pool is cached on `globalThis` for hot reload. |

## Related

- [`../operations/coordinator-deploy.md`](../operations/coordinator-deploy.md) — the production environment file and the REQUIRED-key list
- [`../operations/dev-environment.md`](../operations/dev-environment.md) — the dev VM and its environment
- [`../operations/state-export.md`](../operations/state-export.md) — the `EIGENINFERENCE_STATE_EXPORT_*` runbook
- [`../operations/release-policy-rollout.md`](../operations/release-policy-rollout.md) — `EIGENINFERENCE_RELEASE_POLICY_*` rollout
- [`../architecture/storage.md`](../architecture/storage.md) — the store the DSN selects and the provider's local files
- [`../architecture/components/coordinator.md`](../architecture/components/coordinator.md) — where the coordinator reads its configuration during startup
- [`../architecture/cache-aware-routing.md`](../architecture/cache-aware-routing.md) — `EIGENINFERENCE_CACHE_ROUTING_*`
- [`../architecture/routing.md`](../architecture/routing.md) and [`../architecture/scheduling.md`](../architecture/scheduling.md) — what the routing and admission knobs change
- [`../provider/cli-reference.md`](../provider/cli-reference.md) — the `darkbloom` subcommands these variables act on
- [`ssd-kv-cache.md`](ssd-kv-cache.md) — SSD prefix-cache format and knobs


## GPT-OSS performance controls

These library controls apply to foreground processes and benchmark runs; they are not added to the provider LaunchAgent environment allow-list. Prefix reuse is independent of these changes.

| Variable | Values | Default | Reader and effect |
|---|---|---|---|
| `DARKBLOOM_GPTOSS_PREFILL_OUTPUT` | `full`, `intermediate`, `last`, `last-layer` | `last` | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/GPTOSS+PrefillOutput.swift` (`GPTOSSPrefillOutputPolicy`): skip unused intermediate vocabulary projections and project only the final hidden position. `full` restores full projections; `intermediate` preserves the final full-shape head; `last-layer` additionally narrows the last full-attention layer when its cache supports it. |
| `DARKBLOOM_GPTOSS_FUSED_GATE_UP` | `0` disables; otherwise enabled | enabled for hidden/intermediate width 2880 and 32 experts | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/GPTOSS.swift` (`useFusedGateUp`): concatenate compatible gate/up checkpoint rows. Conflicting quantization policies remain split; incremental materialization bounds the added load transient. |
| `MLX_QUANTIZED_CONSTANT_CACHE` | `0`, `false`, `no`, `off` disable | enabled | `libs/mlx-swift/Source/MLX/ConstantArrayCastCache.swift` (`ConstantArrayCastCache`): bounded reuse of unchanged BF16-to-FP32 constants; updates invalidate and transforms bypass reuse. |
| `MLX_GPTOSS_MXFP4_DECODE_FAST_TAIL` | `1` enables, other explicit values disable | enabled only on physical `applegpu_g16s` | `libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/quantized.cpp` (`gather_qmv`): width-2880 MXFP4 gathered matrix-vector path with a masked 320-element tail. Exact shape/dtype gates retain the general fallback. |
| `MLX_GPTOSS_MXFP4_PREFILL_TILE` | `m32n32k32`; other values use legacy | legacy | `libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/gptoss_mxfp4_policy.h` (`gptoss_mxfp4_prefill_tile`): optional 32-row tile for matching sorted expert prefill shapes. Small workstation gains do not establish a universal default. |
| `DARKBLOOM_GPTOSS_COMPILED_EXPERTS` | `1` enables | disabled | `libs/mlx-swift-lm/Libraries/MLXLLM/Models/GPTOSS+CompiledExperts.swift` (`GPTOSSCompiledExpertsPolicy`): compile single-token B=1/2/4 expert graphs for exact 20B shapes. The global `MLX_COMPILED_DECODE=0` rollback still disables this path. Batch-dependent timing is mixed; weights remain live through weak updatable state. |
