# Changelog

## Unreleased — GPT-OSS prefill and decode

- Skip unused GPT-OSS prefill vocabulary projections, fuse compatible 20B expert gate/up weights with bounded load materialization, reuse unchanged quantized constants, and enable the measured width-2880 MXFP4 decode path on M4 Max. Keep rollback controls and unsupported-shape fallbacks.

- Add sequential, provenance-pinned GPT-OSS profiling with full-shape warmups, raw decode token timing, memory measurements, common-window aggregate B=2/B=4 decode rates, and mixed-length arrival workloads. Preserve failed and diagnostic runs separately from valid baseline measurements; raw evidence and paired comparisons distinguish measurement from optimization.

## Unreleased — stats location refresh

- Restore public stats refreshes on large usage tables by aggregating locations per provider before combining location totals. Preserve distinct-provider and token counts and request-weighted coordinates without sorting every usage row. Keep the selective cutoff's query plan local to the analytics transaction.

## Unreleased — coordinator performance Tiers 2 and 3

- Cache repeated user and model lookups, batch route telemetry writes, and credit balances in one database statement. Invalidate model caches without allowing older in-flight reads to republish stale entries.
- Coalesce streaming output within a byte cap and parse request bodies once.
- Reduce routing scan work with per-model provider indexes, maintained medians, reusable snapshots, bounded version memoization, and coalesced swap and queue-drain planning.
- Commit reservations under the registry read lock and the selected provider's lock. Keep fault tracking on per-identity gates, with validated rebind and sweep handling; retain `EIGENINFERENCE_RESERVE_COMMIT_MODE=global` as the reservation rollback switch.
- Preserve newer rejection state when capacity-accept bookkeeping arrives late.
- Make scheduler, attestation timestamp, and reputation persistence test fixtures deterministic.

## Unreleased — provider lifecycle and bounded coordinator work

- Keep genuine provider 502 faults across version changes; only coordinator-marked disconnect flushes are eligible for reset. Count first-scan TTFT rejections in request outcome telemetry.
- Evict capped zombie tracker entries in constant time, preserving recent activity without per-insertion full-map scans.
- Fragment large provider WebSocket messages, bound queue-drain work, and keep control traffic responsive.
- Fence typed draining refusals at ingress before releasing the request slot; preserve newer recovery heartbeats. Graceful restarts remain health-neutral, and late disconnect errors follow identity enrichment without re-quarantining an upgraded provider.
- Correlate cancel sends and terminals atomically, bound version history and telemetry tags, and retain MLX metrics on HTTP-only Datadog deployments.

## Unreleased (2026-09-04) — console redesign

- Provider onboarding specifies macOS 26 or later.
- Added a Consumer/Provider entry page, dedicated `/chat` route, contextual workspace navigation, and public provider onboarding shared with the empty fleet. Linked providers return to their fleet and recorded earnings, including when their Macs are offline; failed discovery never implies an empty account.
- Scoped fleet requests to the current account, cancelling late results on sign-out or account changes.
- Redesigned console navigation, chat composition, searchable model discovery, settings, and API integration examples.
- Redesigned network stats as one continuous overview: an explorable geography
  map, side-by-side request and token charts, graphical model-capacity lanes,
  linked silicon and memory charts, and an expandable provider directory.
- Stats refresh every 30 seconds. Source timestamps survive cache hits; the
  console proxy coalesces requests and bounds fresh caching to 30 seconds. The
  coordinator retains successful snapshots for up to five minutes on refresh
  failures; older source snapshots are marked stale. The page pauses refreshes
  while hidden and distinguishes unknown capacity from zero.

## Unreleased — coordinator performance Tier 1

- Bound recent in-process usage history with lazy allocation; aggregate dashboard earnings across every row in the rolling windows.
- Refresh public stats and network totals in the background. Preserve unexpired successful data on store failures, return 503 when unavailable, and accept genuinely empty windows.
- Remove capacity-accept bookkeeping from the first-byte path while preserving newer rejection strikes and cooldowns; avoid redundant provider cancels after settled completion.
- Reduce verification polling, coalesce dashboard cache misses, serialize totals queries across windows, batch reputation reads, and throttle successful reputation writes. Add lock-wait/scan instrumentation and preserve unevaluated rejection servability as null.

## Unreleased (2026-09-03) — documentation overhaul

- **Every page under `docs/` rewritten or verified against the code at
  `5d400cf75`** — each page now carries a freshness stamp
  (`> Last updated: <date> · commit <sha>`) naming the code commit its claims
  were checked against; frozen records (`docs/reports/`, `docs/releases/`,
  `docs/legal/`) keep the date and commit of their own last substantive
  change. Claims cite code by path and symbol, not line number. Facts that
  drifted from the code were corrected in place (examples: challenge
  freshness is 16 min not 6; the prefix cache is built only on
  explicitly-paged slots; eviction is two missed 30 s sweeps against a 90 s
  timeout; explicit `max_tokens` is not clamped; the platform fee is stated
  once, in `docs/architecture/billing.md`).
- **Tree reorganised by page type** with `docs/README.md` rewritten as an
  llms.txt-style map (one line per page) and an index per directory.
  `architecture/` holds explanations only — `architecture/operations/*`
  became `architecture/{billing,model-registry,routing,scheduling,telemetry}.md`
  and `architecture/prefix-cache.md`, `architecture/components/admin-ui.md`
  are new; `reference/` gains `configuration.md` (every environment variable
  of the coordinator, provider CLI, console and admin UI, with defaults and
  the symbol that reads it) and `telemetry-inventory.md`; plans and ADRs live
  in `design/` with a status line each (`design/README.md`); dated frozen
  records live in `reports/` (`reports/README.md`; twelve reports that were
  sitting uncommitted are now in the tree); `glossary.md` gives one name per
  concept. Merged as duplicates: `architecture/payments.md` →
  `architecture/billing.md`, `provider/security-model.md` →
  `provider/attestation.md`, `reference/ssd-kv-cache-hybrid-models.md` →
  `reference/ssd-kv-cache.md`; PR screenshot folders removed. Security
  diagrams redrawn from the code (`docs/assets/diagrams/*.mmd` → SVG/PNG).
- **One home per fact** (follow-up to an organisation audit of the new tree)
  — every constant, default, limit and status code is now stated on one owner
  page (`reference/api-contracts.md`, `reference/configuration.md`,
  `reference/pricing-model.md`, the owning `architecture/` page) and linked,
  by identifier, from every other page; operator procedures and SQL recipes
  left the explanation pages for `operations/cache-routing-rollout.md` and
  `operations/profiler-queries.md`; `developer/release.md` became
  `operations/provider-release.md` (it registers releases with production);
  six plan and decision memos moved from `reports/` to `design/` with a
  status line each (`design/README.md` lists all seventeen with status and
  date); `provider/attestation.md` is now the operator how-to for reaching
  and keeping `hardware` trust, and `consumer/privacy-expectations.md` a
  short list that links the encryption page instead of restating it.
- **Docs tooling** — `scripts/docs-stamp.sh` writes or refreshes the stamp
  (`--from-git` for frozen records); `scripts/docs-check.sh` fails on a
  missing or malformed stamp, a relative link that does not resolve, a cited
  code path that does not exist, or a page no index links to. `make
  docs-check` / `make docs-stamp`; `make test` runs the check; CI gains a
  "Docs Lint" job. `docs/AGENTS.md` states the rules for humans and agents:
  one job per page, one canonical home per fact, cite the code, stamp on
  every edit, and the page skeleton for each page type.
- **Root pointers** — `README.md`, `CONTRIBUTING.md`, `AGENTS.md` and
  `CLAUDE.md` point at the new paths, and the "coordinator never sees
  plaintext" claim was replaced by the hop-by-hop encryption model documented
  in `docs/architecture/security/encryption.md`. Code comments that named
  moved docs were updated (comment-only edits in `coordinator/`,
  `console-ui/`, `provider-swift/`).
- **Re-verified against `ac60c5ada` (#816)** — the runtime manifest's
  union-across-active-releases semantics, the `GET /v1/runtime/manifest`
  shape and the `EIGENINFERENCE_KNOWN_TEMPLATE_HASHES` override are stated
  once, in `docs/architecture/security/attestation.md#runtime-manifest`, and
  linked from the provider-release and release-policy runbooks.

## Unreleased (2026-09-02) — system profiler

- **Runtime manifest accepts every active release** — `SyncRuntimeManifest`
  now unions template hashes (including `mlx_metallib`) across ALL active
  release rows instead of keeping one value per template name. Registering
  v0.8.16 on 2026-09-03 replaced the v0.8.15 metallib hash in the manifest, so
  ~1,180 providers still on v0.8.15 failed their next attestation challenge
  (`provider runtime integrity mismatch in challenge response`, 1,184 times)
  and the fleet was unroutable for the ~30–40 minute self-update window.
  Registering a release can no longer deroute the previous release's fleet;
  deactivating a release remains the way to retire its hashes, a hash no
  active release ships still fails closed, and `GET /v1/runtime/manifest`
  lists every accepted hash per template. The post-mutation convergence paths
  and the `EIGENINFERENCE_KNOWN_TEMPLATE_HASHES` override use the same set
  semantics.
- **Per-request profiler** — the coordinator records one prompt-free row per
  dispatched attempt in `request_profiles` (joins `inference_routes` on
  `(request_id, attempt)`): microsecond offsets from middleware entry for every
  coordinator stage (auth, parse, reserve, media, preflight, plan, reserve lock
  wait/scan/admit, queue, encrypt, writer submit/dequeue/wire, provider ack,
  chunk ingress, first content, headers, flushes, `[DONE]`, client-gone,
  cancel, completion ingress, settlement), the routing decision context
  (gate rejections by closed reason, top-4 candidates, runner-up, best idle
  alternative, near-tie size, selection path, heartbeat age at decision,
  predicted vs raw TTFT, calibration ratio, queue position/drain trigger), and
  a validated provider profile: the provider now sends an optional `profile`
  object on `inference_complete`/`inference_error` (decrypt/parse/admission/
  model-load wait/prompt prep/engine submit & admitted/first & last delta/
  terminal build & send/cancel stage, plus the engine's own
  `CBv2RequestTiming`: admission, KV allocation, prefill chunks, prompt
  computed, first token, decode steps and batch rows, MTP accept counts,
  pauses, detokenization delay, prefix-cache lookup/adoption). Numbers,
  booleans and closed enums only; validated, folded and stored from a separate
  closed struct; never routing-, billing- or health-affecting.
- **Fleet snapshots** — `fleet_snapshots` samples every provider slot each
  minute (running/waiting, budgets, KV bytes, EWMAs, MTP totals, eligibility
  reason, cooldown/breaker/clamp flags, heartbeat age, cumulative cancel
  counters, low-power/thermal posture) plus a coordinator row (queue depth by
  model, in-flight, sink depth/drops, zombie-frame count). Heartbeats carry new
  optional `telemetry` sub-objects; `eval_in_flight_ms` finally has a producer.
- **Egress and attempt accounting** — non-streaming 200 bodies stamp the same
  first/last flush and bytes-out fields as SSE relays; attempts that never reach
  a provider close only their terminal half at the failure site so the record is
  built after the handler returns; a speculative primary cancelled for the
  first-content timeout keeps its timeout outcome even when the backup wins the
  ingress race.
- **Review hardening** — heartbeat-reported counts are clamped to the snapshot
  column range so one bad heartbeat cannot abort a fleet sample batch; the
  recorded TTFT calibration ratio is the one the candidate was scored with;
  routing replays count `no_provider` / `model_too_large` explicitly; terminal
  usage is recorded at ingress (outside billing) and each provider-profile
  consistency check runs independently; a speculative loser's discarded empty
  completion still closes its attempt row.
- **Operations** — admin browse/NDJSON export for both tables
  (`/v1/admin/profiles`, `/v1/admin/snapshots`), a manual `request_waterfall`
  view, retention sweeps (14 d / 30 d), a dedicated batched profile sink with
  `telemetry.sink_dropped{sink}` / `telemetry.sink_depth{sink}` metrics,
  `inference.unknown_request_frames{kind}`, knobs `EIGENINFERENCE_PROFILER=off`
  and `EIGENINFERENCE_PROFILE_SAMPLE_RATE` (default 0.1; slow, failed, retried,
  backup and client-gone requests are always recorded), routingsim NDJSON
  loaders for profile and fleet exports, `request_rejections.request_id`
  populated with a coordinator-minted id. `X-Timing` keeps its legacy keys
  (clamped, `timing_anomaly` flag) and gains additive `pre_handler_us`,
  `preflight_us`, `route_reserve_us`, `queue_pure_us`, `writer_us`,
  `socket_us`, `provider_ack_us`. Docs: `docs/architecture/system-profiler.md`,
  `docs/reference/telemetry-inventory.md`; threat model T-051.

## Release candidate v0.8.16 (not shipped; 2026-08-31)

- **Per-model activation floors + measured resident weights** — the flat
  5.5 GiB activation reserve is now resolved per serving set from measured
  per-model floors (gpt-oss-20b: 3.5 GiB — its load requirement drops from
  20.0 to 18.0 GB, which narrows the 32 GB flap band reported in #653 by ~2 GB; the
  24 GB catalog tier stays borderline until the admit-time weight padding and
  the small-box `memory_reserve_gb` default are revisited, #653/#683), and the coordinator's
  POST-load token-budget estimate uses measured MLX residency for measured
  text-only artifacts (gpt-oss-20b: 11.5 GiB steady vs the 13.5 padded
  estimate) via `servabilityColdWeightsGiB`, version-gated at 0.8.16.
  ADMIT-time gates — provider load gate and the coordinator's cold-load
  admit — deliberately keep the padded disk×1.2 figure: it covers the load
  transient (shard staging), which steady residency does not. Vision-capable models (the qwens, the gemma VLM builds) keep the
  flat floor and padded weights until vision-inclusive measurements exist;
  measured text baselines and the full sweep live in
  `docs/reports/2026-08-30-activation-floor-measurements.md`.
- **Serving-set reserve race hardening** — epoch-stamped reserve pushes
  (cross-actor delivery is not FIFO), in-flight loads join the reserve
  basis, failed-load cleanup holds the load gate through its awaits,
  shrink paths regrow survivor grants, and failed-self-test retirement is
  fail-closed end to end: durable failed-hash record (slot-bound hash or
  refuse-all sentinel) consulted at every prefetch guard, a retirement
  tombstone spanning foreign-owned drains, registration convergence on the
  announce-undo, and new-inference rejection on both resident-slot fast
  paths while a retirement drains.
- **MLX-LM pin advances past the 0.32.2 core bump** — on top of #790's
  `libs/mlx-swift-lm` pin (`81dd564`, which already carried Qwen3-VL CBv2
  DeepStack #125 and the dense Qwen3.8 MTP artifacts #118), this release
  moves to `30da946`: the gather-QMM sorted-hint lane
  ([#126](https://github.com/Layr-Labs/mlx-swift-lm/pull/126)), vision batch
  performance ([#127](https://github.com/Layr-Labs/mlx-swift-lm/pull/127)),
  a serving-correctness batch
  ([#128](https://github.com/Layr-Labs/mlx-swift-lm/pull/128)), and the
  bench-harness hybrid-trunk paged fix
  ([#129](https://github.com/Layr-Labs/mlx-swift-lm/pull/129)).

## Release candidate v0.8.15 (not shipped; 2026-08-28)

- **Exact Qwen3.8 dense VLM artifact** — Providers serve
  `EigenLabs/Qwen3.8-27B-4bit` at immutable revision
  `301e9e2767fd0efcfab7883004720ba3c9a552a1`. The dense Qwen3.5 text target
  is extracted from the loaded VLM wrapper for ContinuousBatchingV2 while
  retaining shared immutable weights, recurrent/KV sizing, causal visual spans,
  request-owned M-RoPE state, cancellation, deadline, and MLX fault boundaries.
  Image processing remains one tower invocation per image. API video remains
  one full T×H×W tower invocation per video followed by ordered frame-output
  splitting; console/UI video upload is not enabled.
- **Exact separate Qwen3.8 MTP artifact, model-specific default on** —
  `EigenLabs/Qwen3.8-27B-MTP-4bit` at immutable revision
  `329261c5e0b3f9c233485e682cb3b67b88c20a55` is loaded only as a proposal
  assistant; the target remains authoritative for acceptance and output.
  Absent MTP config enables this exact target only. Explicit `mtp_mode = "off"`
  (including `darkbloom beta disable mtp`) and the
  `DARKBLOOM_CBV2_MTP=0` process kill switch independently restore target-only
  decoding. Explicit `on` remains available for other supported targets.
  Missing, malformed, unavailable, incompatible, or memory-inadmissible
  assistant state falls back to target-only decoding with a stable reason.
- **Unified Qwen template and tool controls** — Remote encrypted text/vision,
  local single/batch, and prompt recount paths share one template-control
  value. Nested `reasoning.enabled` wins over top-level or
  `chat_template_kwargs.enable_thinking`; only `none`, `off`, and `0` disable
  through `reasoning_effort`, `minimal` is preserved, media defaults thinking
  off only with no explicit control, and `preserve_thinking` is forwarded.
  Forced Qwen tool calls remain withheld until XML parsing, function selection,
  and schema validation succeed; the exact concrete model advertises the
  capability only for the `qwen3_coder` XML parser contract.
- **Capability-gated rollout and integrity** — The exact concrete model is
  restricted by the shared provider capability evaluator to Apple M5 with the
  approved NAX runtime. `video_preprocessor_config.json` is included in model
  integrity manifests. Provider version advances to `0.8.15`; no protocol
  fields are added.

## Release candidate v0.8.14 (not shipped; 2026-08-26)

- **Qwen3-VL 30B-A3B production serving** — The exact
  `qwen3_vl_moe` architecture is admitted through the contiguous
  ContinuousBatchingV2 path. Text decode uses per-row M-RoPE positions; image
  prefill carries causal visual spans, every DeepStack level, and the model's
  embedding activation dtype. Homogeneous routed-expert gate/up projections are
  fused at load time, reducing each MoE layer from three gathered projections
  to two while retaining a strict split fallback for heterogeneous
  quantization. Paged KV, video, packed prefill, prefix reuse, compiled decode,
  and MTP remain fail-closed for this family.
- **Qwen 3.5/3.6 inline MTP defaults to automatic** — New
  `mtp_mode = "auto" | "on" | "off"` keeps Gemma opt-in while valid inline
  `qwen3_5_moe` artifacts activate by default. Explicit `off` and
  `DARKBLOOM_CBV2_MTP=0` remain independent rollback controls. Config schema
  v3 migrates the legacy generated `mtp = false` default to `auto` so upgraded
  providers receive the policy, retains legacy `true` as `on`, and preserves a
  new explicit `mtp_mode = "off"` override.
- Provider and coordinator fallback version authorities move together to
  `0.8.14`; there is no new wire protocol.

## Release candidate v0.8.13 (not shipped; 2026-08-25)

- **Qwen 3.5 video + grounded image captions** — Qwen vision prefill no
  longer fail-closes video as `invalid media input`. The tower runs one
  video (full T×H×W grid) at a time and carves the contiguous
  `<|video_pad|>` run into per-frame spans. Image decode applies EXIF
  orientation on the full raster (not a JPEG thumbnail). Media requests
  default `enable_thinking=false` unless the client sets
  `reasoning.enabled`. Qwen decodes media once and uniformly samples at most
  8 video frames at no more than 512² pixels each, bounding its unfused
  vision score tensor to 512 MiB. Coordinator remote-media fetch is bounded
  by the leftover first-content clock minus an inference reserve, and media
  bypasses the text-only estimated-TTFT hard gate while retaining the same
  request-absolute deadline. Its incomplete estimates do not train text TTFT
  calibration or emit synthetic warm-pool pressure.
- **Current MLX-LM main pin** — `libs/mlx-swift-lm` advances to `fe01df9`,
  containing the merged Qwen prefill/decode optimization
  ([mlx-swift-lm#120](https://github.com/Layr-Labs/mlx-swift-lm/pull/120))
  and bounded video-tower input fix
  ([mlx-swift-lm#123](https://github.com/Layr-Labs/mlx-swift-lm/pull/123)),
  plus Qwen3-VL 30B-A3B support
  ([mlx-swift-lm#122](https://github.com/Layr-Labs/mlx-swift-lm/pull/122)).
- Provider and coordinator fallback version authorities move together to
  `0.8.13`; there is no new protocol.

## v0.8.12 (shipped; 2026-08-25)

> **Post-publication status:** `v0.8.12` was tagged, published, and registered
> before the Qwen media fixes above. Those fixes therefore ship in v0.8.13.

- **Default atomic first-token deadline admission on** — Explicit typed TOML is
  authoritative: `"off"` disables and `"enforce"` enforces regardless of the
  legacy environment. An absent key inherits that environment, where only exact
  lowercase `off` disables and every other value securely enforces. Optional
  serialization preserves absence. Edit `provider.toml` and use ordinary
  `darkbloom restart` for rollback, restore, or legacy-environment inheritance;
  the linked report gives the exact settings.
- **Keep the safety envelope unchanged** — Forecasting still requires a
  propagated deadline, an initialized isolated cold-prefill EWMA, a text-only
  request, phase-specific rates, and an authoritative capacity-guaranteed
  scheduler projection. Multimodal requests remain outside forecast admission.
- **Keep cap-0 a functional serving rollback** —
  `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS=0` still restores unlimited partial
  prefill interleave. That posture cannot produce the proven bounded projection,
  so it bypasses forecast admission and uses ordinary submission while hard
  absolute expiry remains active. It does not rewrite the deadline-mode setting.
- Provider and coordinator fallback version authorities move together to
  `0.8.12`; there is no new protocol.

Release rationale, limitations, compatibility, and rollout gates:
[`docs/reports/2026-08-25-v0.8.12-prefill-deadline-admission.md`](docs/reports/2026-08-25-v0.8.12-prefill-deadline-admission.md).

## v0.8.11 (shipped; 2026-08-24)

> **Post-publication status (2026-08-25):** `v0.8.11` was tagged, published, and
> registered as the active provider release. The candidate notes below are
> retained as the pre-publication decision record; their blocker/no-shipment
> language describes the state when they were written. The shipped resolver
> still defaulted atomic deadline admission to `off`; v0.8.12 is the activation
> change.

### Candidate integration status

- **v0.8.11 enables FCFS partial-prefill scheduling globally** — Production
  resolves `maxConcurrentPartialPrefills` to `1` for every CBv2 model. Operators
  can immediately restore the historical unlimited interleave with
  `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS=0`; other explicit non-positive or
  malformed values also fail open to unlimited behavior.
- **Deadline conservation and atomic admission plumbing ships
  provider-default-off** — Remaining first-content budget propagation is
  additive and fail-open for older peers. The queue-excluded prefill EWMA,
  engine atomic forecast API, and provider wiring are integrated, but forecast
  enforcement remains disabled unless exact mode `enforce` is selected.
  Default-on FCFS is the separate global scheduling policy above.
- **FCFS evidence remains a release blocker** — Cap 1 can improve mean burst
  TTFT, but it can also remove Qwen packed-prefill cohorts and head-of-line-block
  short prompts. The only real-model attempt was aborted after approximately
  27 minutes at 13% battery and produced no artifact. No signed-candidate
  cap-0/cap-1 report or representative non-Qwen evidence exists yet.

### Coordinator candidate fixes

- **Enforce one request-absolute first-content deadline** —
  Queueing, provider acceptance, boilerplate/preamble frames, speculative
  dispatch, and blocked provider writes must not reset the clock. Expiry must
  cancel in-flight work and return the existing retryable `429` contract
  without feeding provider-fault breakers unless the provider received a full
  attributable wait window.
- **Price routing from live prefill behavior** — The base request-cost
  term now uses the same measured-preferred prefill resolver as TTFT estimation,
  falling back to the static registration rate when no observation exists.

### Provider candidate fixes

- **Default partial-prefill concurrency to one with an immediate rollback** —
  The production factory applies cap 1 globally. Exact environment override
  `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS=0` restores unlimited interleave without
  a code change.
- **Honor the coordinator's remaining first-content clock** —
  A positive wire budget becomes one provider-local monotonic deadline. The
  provider refuses expired pre-submit work and releases any partial
  admission/cache resources instead of restarting the budget at model load or
  engine submission when enforcement is enabled. Default-off and absent
  metadata paths remain fail-open; coordinator cancellation remains the
  authority after submission.
- **Add an honest FCFS evaluation harness** — The opt-in five-workload matrix
  compares caps 0 and 1, cryptographically records the selected checkpoint,
  omits local model paths, records source/binary/build/hardware/OS/power/thermal
  posture, and evaluates the documented 5% throughput and TTFT thresholds. Its
  schema distinguishes simulation, unsigned local evidence, and evidence
  captured by the signed packaged main executable. Signed Qwen evidence remains
  model-family evidence only and never sets global release certification.
- **Add a fail-closed signed-artifact FCFS command** — Run the exact packaged
  candidate with:

  ```bash
  "$SIGNED_APP/Contents/MacOS/darkbloom" benchmark \
    --scheduler-prefill-decision \
    --model "$QWEN_MODEL_ID" \
    --expected-model-aggregate-sha256 "$QWEN_MODEL_AGGREGATE_SHA256" \
    --expected-registered-binary-sha256 "$REGISTERED_DARKBLOOM_SHA256" \
    --expected-version 0.8.11 \
    --source-sha "$SOURCE_SHA" \
    --decision-iterations 10 \
    --kv-backend auto \
    --output "$QWEN_SIGNED_REPORT"
  ```

  It accepts no weights path and resolves the canonical registry ID internally.
  It exits successfully only after packaged signature, identifier/team,
  registered binary hash, version, model hash, posture, and policy checks pass.

### Release requirements

- Pass coordinator/provider focused tests, protocol symmetry, mixed-version
  behavior, full builds, system E2E, signed artifact checks, and rollback gates
  recorded in
  `docs/reports/2026-08-24-qwen-openrouter-timeout-fix-and-release.md`.
- Do not ship the default-on FCFS policy until an externally captured
  signed-candidate artifact passes the cap-0/cap-1 criteria on representative
  Qwen hardware, plus equivalent latency/throughput/head-of-line evidence for
  every affected non-Qwen CBv2 family or a separately reviewed model-scoped
  policy. The unsigned local harness cannot satisfy this requirement.

---

The entries below are earlier shipped releases. At the time the v0.8.11
candidate notes above were recorded, the latest shipped provider was `v0.8.10`.

## v0.8.10 (2026-08-21)

### Provider (Swift)

#### Fixes

- **Seed retained optimization latches before packaged-child exec** — The v0.8.9 curl installer could download and verify the signed bundle but reject it with `safe R1 was not latched as requested` on hosts where MLX initialized Metal before `runtime-smoke.run()`. Installer, self-updater, and paged preflight children now receive the exact retained three-key environment (`DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL=18`, `MLX_GEMMA4_FUSED_WEIGHTED_UNSORT=1`, `MLX_GATHER_QMM_EXPERT_SLICES=1`) at process launch, while the child still poisons/reapplies/verifies the values and AOT kernels. Existing installations remain untouched on any failed verification.

## v0.8.9 (2026-08-21)

### Provider (Swift)

#### Fixes

- **Emergency Qwen3.6 runtime rollback** — Restores the v0.8.7 `mlx-swift-lm` pin (`ab73a827`) and removes v0.8.8's default-on GDN four-input projection fusion and direct weighted-expert reduction. In the fixed one-hour production comparison, Qwen success fell 85.52%→65.79%, p50 decode fell 38→26 tok/s, client timeouts approximately doubled, and the hard TTFT gate emitted 612 429s (602 marked counterfactually serveable). M1/M2 providers regressed even though they cannot use affine `qmv_wide`, isolating the Qwen runtime changes as the first rollback target. Gemma's merged `qmv_wide` MLX/MLX-Swift pins remain enabled for continued benefit and separate attribution.
- **Restore the retained runtime-smoke contract** — Removes the retired Qwen process-global reduction key from serving projection, launchd passthrough, signed-child validation, and benchmark-report expectations. Provider artifact verification returns to the three retained Gemma controls.

## v0.8.8 (2026-08-21)

### Provider (Swift)

#### Performance

- **Default-on small-batch quantized matvec (`qmv_wide`)** — Ports upstream MLX #3764 (`548dd80e`) into the Darkbloom MLX fork and regenerates MLX-Swift's embedded JIT Metal sources. On generation-15+ Apple GPUs, affine BF16 W4/W8 dense projections with `2 <= M < vector_limit` reuse each decoded weight group across the small activation-row tile; M=1 remains on QMV, matrix-sized inputs remain on QMM, and gathered expert projections are unchanged. Source-built metallib and release-artifact checks require representative W4/W8 ordinary and batched symbols. Local M4 Max directional medians preserved B=1 and improved Gemma B=4 aggregate decode 195.93→216.94 tok/s at 512 context (+10.72%) and 143.18→155.72 tok/s at 8K (+8.76%); B=2 was +4.49%/−1.00%. The attempted 32K comparison is intentionally unclaimed because both benchmark arms entered a persistent degraded host/device state.

#### Default posture

- `qmv_wide` is an automatic Metal dispatcher route, not a beta flag: eligible generation-15+ affine `2 <= M < vector_limit` projections take it by default. Gemma layer-18 submission, coupled weighted-unsort/safe-R1, expert-tile trust, solo-prefill stripe, prompt narrowing, and packed-prefill defaults remain enabled for existing and new provider configurations.

## v0.8.7 (2026-08-20)

### Provider (Swift)

#### Fixes

- **Restore Qwen3.5/3.6 system-history normalization** — The compatibility fix released on the `v0.8.5` branch was absent from master and therefore from `v0.8.6`, causing Qwen's published template to reject OpenAI-compatible histories with a late system turn (`System message must be at the beginning`). Production Qwen 422s rose from 3.46–4.95% on `v0.8.5` to 27.73–33.95% on `v0.8.6`. Text-only system turns are again folded into one leading system message before generic tool-history validation; structured/media system content remains fail-closed.

## v0.8.6 (2026-08-20)

### Provider (Swift)

#### Performance

- **CBv2 prefill stack, default-on** — Cold prefill 6,406.8 → 4,636.9 ms at 8K on the M4 Max prod artifact (**~1,766 tok/s, +38% vs v0.8.5 defaults**); 4×8K burst aggregate 1,312 → ~1,500 tok/s (+13–17%) with token-checksum parity across every arrival pattern. Four independently escapable levers (#646, mlx-swift-lm#111):
  - *Expert-tile `trust` serving default* — skips the per-chunk descriptor retract drain (80 stream drains/chunk); exact `MLX_GATHER_QMM_EXPERT_SLICES=1` restores the drain posture. (#638)
  - *Solo-prefill stripe (2048)* — when exactly one live text request holds the scheduler, its chunk widens 512→2048 (weights streamed 4× less often, full 32-row expert tiles). Armed per-plan; any company disarms to plain 512s; KV-capacity failure shrinks once, never preempts; the stripe budget belongs exclusively to the armed row. `DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE=0` disarms. **Known trade: ~12% TTFT regression under Low Power Mode — throttled/battery providers should export the escape.**
  - *Recurrent prompt narrowing (Qwen LM head)* — intermediate chunks return a one-element handle instead of the `[1,512,248320]` logits tensor (242.5 MiB/chunk); the frontier chunk norms + projects exactly one row. `DARKBLOOM_CBV2_PREFILL_NARROWING=0` restores byte-old behavior.
  - *Packed prefill (Qwen3.6)* — equal-length prompt chunks from concurrent requests run as one `[B,L]` forward with per-row recurrent state (one weight stream per cohort; text-only v1).
- **Mean-TTFT prefill serialization** *(opt-in)* — `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS=1` caps rows receiving prompt work per step (FCFS): burst TTFTs become a staircase instead of everyone waiting for the makespan. Paused rows hold no slot (a stalled consumer cannot head-of-line block admission). (#646)
- **Adaptive persistent-history MTP promoted onto master** *(still behind the `mtp` beta flag)* — the v0.8.5-described capture-verify stack's adaptive width selection and persistent head KV now ship in the release pin. (#641, mlx-swift-lm#110)

#### Benchmarks / Tooling

- Scheduler-prefill report schema 3 (records the effective stripe posture); Gemma contbatch wrapper schema 6 — baseline pins refuse pre-default-flip reports so the posture change can never masquerade as a code delta. 14 review-hardening scheduler fixes with regression tests; measurement methodology + posture discipline in `docs/reports/2026-08-19-solo-prefill-stripe-experiment.md`. (#646)

## v0.8.5 (2026-08-14)

### Provider (Swift)

#### Performance

- **Qwen3.6 E=256 expert-tile prefill route + fused gate_up** - Instantiates the Gemma4 descriptor/tile kernel family for Qwen's 256-expert shapes (mlx `d3c82db`), fuses the routed gate/up projection into one gather (`SwitchGLU(fuseGateUp: true)`, per-layer and per-load with heterogeneous-quantization split fallback across every checkpoint key space), and adds the opt-in `trust` refinement that skips the per-chunk retract drain. Measured on M4 Max, prod artifact: routed MoE block -26.3% at T=512; end-to-end prefill 1243→1364 tok/s default, 1433 with `trust` (+15.2%) at 8k; 2k +7.4%, 32k +6.6%. (#617, mlx-swift-lm#107)
- **Qwen3.6 MTP: adaptive persistent-history capture-verify stack** *(behind the `mtp` beta flag, default off)* - Selects one rectangular k=0...4 per scheduler plan/decode-row bucket from request-local acceptance probabilities and shared marginal-cost evidence, obtains policy confidence with a lazy hierarchical Metal top-2 reduction, and keeps complete committed context in request-owned MTP-head KV; leading trusted history now appends K/V only, so each round computes full head output only for its final row. Target verification remains one `[B,1+k]` forward with target-prefix-authoritative acceptance at any temperature. Widths 1/2 use captured recurrent state; S>=3 runs one full-window recurrence, commits the final state directly on full acceptance, and retains compact transformed inputs for lazy strict-prefix replay instead of full per-position recurrent stacks. Request-owned head/history and recurrent replay residency are charged exactly by admission. A combined production-bundle **DEBUG canary validation** on this M4 Max measured median target 7.657386s vs MTP 3.813989s (**2.0077x**); this is validation evidence, not release throughput. (#616, mlx-swift-lm#106/#108/#110)
- **mlx gpu::eval use-after-free fix** - A stale `MTL::CommandBuffer` captured across `eval_gpu` could crash any primitive that syncs mid-eval (deterministic SIGSEGV on the E=256 route; previously survived on allocator luck). (mlx#5/#7)

#### Fixes

- **Inline-MTP inspection resolves HF-cache symlinks and rejects loudly** - Symlinked snapshots (the standard HF `blobs/` layout) silently disabled inline MTP: `inspectInlineArtifact` required regular files and reported nothing. Inspection now resolves links and validates targets; every genuine rejection logs a concrete reason and path. Untrusted operator-path inspection stays symlink-rejecting. (#618)

#### Observability

- **MTP posture and acceptance on the local `/metrics` endpoint** - `mtp_enabled`, `mtp_active`, `mtp_rounds_total`, `mtp_tokens_proposed_total`, `mtp_tokens_accepted_total`, and `mtp_inactive_reason{model,reason}` (including `inline_artifact_invalid`) in both `--local` and unified serving modes - acceptance was previously observable only in Datadog Logs. (#619)

### Coordinator

#### Fixes

- **Expose exact Hugging Face repositories in model feeds** - Registry metadata can now override `hugging_face_id` independently of the internal routing ID. Both `/v1/models` and `/v1/models/openrouter` honor the override for concrete and aliased models, with an authenticated `hugging-face-id` admin action for existing registry rows. (#620)

---

## v0.8.4 (2026-08-13)

### Provider (Swift)

#### Fixes

- **Stream Qwen3.6 reasoning deltas immediately (TTFT fix)** - Qwen3.6-style chat templates pre-open the `<think>` block at the prompt tail, so model output carries only the closing tag and the streaming think parser buffered the entire block before emitting anything: measured prod TTFT was `755ms + 12.51ms x reasoning_tokens` (r = 0.9878) while the first byte arrived in ~76ms. The engine now probes the rendered prompt tail (`ReasoningPromptProbe`) and injects one synthetic `<think>` open ahead of model output — gated on an active think-format parser and streaming — so `reasoning_content` streams per chunk and TTFT reflects real first-token latency. Text and VLM paths; the marker never reaches the prompt, the consumer, or the TB-007 hash domain. (#614)

---

## v0.8.3 (2026-08-12)

### Provider (Swift)

#### Features

- **Qwen3.6-35B-A3B VLM with inline MTP** - Adds production-path text, image, and tool inference for the combined Qwen artifact. The runtime preserves request-owned recurrent and three-axis mRoPE state, causal vision attention, exact rollback, and source-matched target/assistant memory accounting. MTP remains depth-one, serial, and exact-target-verified; video, prefix reuse, paged KV, compiled decode, packed prefill, and rectangular MTP remain fail-closed.

#### Release Safety

- The model is registered as beta/ready without an alias or active-version promotion. Provider rollout and model promotion remain separate reviewed operations after the signed `v0.8.3` bundle passes a controlled fleet canary.

---

## v0.8.2 (2026-08-10)

### Provider (Swift)

#### Performance

- **Gemma 4 26B-A4B v0.8.2 optimization stack** — Layer-18 lazy prefill submission; coupled weighted-expert-unsort + safe-R1 expert-QMM gate (both default-on via `[gemma_optimizations]`); the VLM wrapper's directly shared text tower; packed multimodal prefill inside q=128 query blocks; source-matched metallib enforced across CI/release/packaged smoke. Final performance and retention deltas are pending a same-tree A/B measurement on the reviewed release tree. Earlier gitignored measurements predated the final kernel edits and are not release evidence. Dropped before the final cut: expert gate/up packing, dense gate/up packing, standalone weighted-unsort, standalone R1. `0cc5fc9c9`

#### Security

- **Keep inline video plaintext off disk** — The provider decodes coordinator-inlined MP4/QuickTime bytes through a bounded, memory-backed AVFoundation asset, retains the byte owner through metadata probing and frame sampling, and rejects external asset references. Exact-name legacy `vlm-<UUID>.mp4` files are purged once after single-instance lock acquisition on both coordinator-connected and standalone launch paths.
- **Close unintended provider-derived plaintext egress paths** — Provider inference failures cross the WebSocket and client boundary only as closed-vocabulary codes/reasons, while browser/provider free-form telemetry and automatic provider log reporting are retired. The explicit `darkbloom report` support command remains operator-initiated, preserves macOS unified-log privacy redaction, supports local `--dry-run` review, and uses authenticated upload plus admin-only retrieval.

---

## Unreleased (Apr 26 - May 25, 2026)

26 commits since `aa74499`.

### Coordinator

#### Features

- **DB-backed model registry** (#203) -- Model catalog is now stored in Postgres with R2-hosted manifests. Includes readable prefixes, runtime limits, runtime parameters, hardened validation, and provider inventory preservation across catalog updates. `50e8887b`
- **Token-budget routing with engine-level admission** (#171) -- Replaces heuristic-based routing with engine-reported capacity signals. Providers report real `activeTokens`, `maxTokensPotential`, and token budget usage. Coordinator uses EWMA observed TPS, fleet median fallback, and token-budget admission. 5 new fields on `BackendSlotCapacity` (backward-compatible). 25+ new tests. `78314b4e`
- **Speculative TTFT dispatch** (#171) -- Parallel dispatch to a backup provider at 50% of the TTFT deadline. First provider to deliver a token wins; loser is cancelled. No double-billing. OpenRouter TTFT SLA enforcement (5s base + 1ms/input token). `78314b4e`
- **Early 429 with Retry-After for capacity signaling** (#171) -- Returns 429 instead of 503 when fleet is at capacity (no uptime penalty on OpenRouter). `GET /v1/models/capacity` endpoint for observability. `ModelCapacitySnapshot` with per-model routable/warm/cold providers, aggregate TPS, estimated TTFT, and token budget headroom. `78314b4e`
- **Coordinator-driven model preload protocol** (#110) -- New `load_model` / `load_model_status` WebSocket messages allow the coordinator to push model warm-up requests to providers ahead of demand. `56b050b4`
- **Datadog observability stack** (#143) -- DogStatsD, APM, journald log collection on dev GCE VM. Structured metrics: attestation counters, model_type tags, provider-count gauges, completion-tokens counter, fleet version/binary hash observability, billing histograms (reservation, settlement, provider credits, platform fees), store latency, input token metrics. `56b050b4`
- **X-Timing latency decomposition header** (#136) -- Single JSON header with per-phase microsecond breakdown: `parse_us`, `reserve_us`, `route_us`, `queue_us`, `encrypt_us`, `dispatch_us`, `provider_us`. `56b050b4`

#### Bug Fixes

- **Structured JSON 404 for unimplemented /v1/* endpoints** (#168) -- Catch-all handler returns `application/json` errors instead of Go's default `text/plain` 404. Prevents OpenAI SDK parse failures on `/v1/embeddings`, `/v1/moderations`, etc. Added openai-go SDK compatibility tests. `e108da5f`
- **OpenAI error response `code` and `param` fields** (#144) -- `errorResponse` now populates `code` and `param` per the OpenAI API spec. `insufficient_quota` canonical code, `param="model"` on model errors. All 202 existing call sites backward-compatible. `e108da5f`
- **Require country for Stripe payout onboarding** (#179) -- `2e262b73`
- **Stripe dashboard metadata** -- `35582c82`
- **Prevent double-decrement on untrusted provider disconnect** (#143) -- `MarkUntrusted` race fix: hold write lock through counter decrement. Heartbeat no longer revives untrusted providers. `56b050b4`
- **Skip Python/dangerous-modules check for Swift runtime** (#143) -- Private text routing gate correctly bypasses Python-specific checks for Swift providers. `56b050b4`
- **Fix planner pending leak** (#171) -- Changed `planner.complete()` to `planner.cancel()` in request completion path. Without this, pending entries accumulated until `maxQueuedRequests` (128), permanently bricking the provider. `78314b4e`
- **Refund provider-specific extra on generic dispatch** (#171) -- All 14 failure paths after `reserveAdditionalForProvider` now refund the delta in `handleGenericInference`. `78314b4e`
- **activeRequests counted per-model, not per-provider** (#171) -- `ModelCapacitySnapshot` now counts only pending requests matching the specific model. `78314b4e`
- **Link test providers to user account** (#174) -- Ensures payout destination check passes for test providers. `f4219c4f`

#### Breaking / Protocol Changes

- **Go module path changed** -- `github.com/eigeninference/coordinator/internal/X` -> `github.com/eigeninference/d-inference/coordinator/X`. Module path is now `github.com/eigeninference/d-inference`. `coordinator/internal/` flattened to `coordinator/`. `56b050b4`
- **Bundle filename changed** -- Coordinator now accepts `darkbloom-bundle-<platform>.tar.gz` (was `eigeninference-bundle-`). `56b050b4`

---

### Provider (Swift)

#### Features

- **Swift provider runtime shipped** (#110) -- Full `darkbloom` CLI with `serve`, `start`, `stop`, `status`, `doctor`, `models`, `benchmark`, `login`, `logout`, `enroll`, `update`, `verify` subcommands. Production inference via MLX-Swift on Apple Silicon. GPU-only enforcement. Rename from `eigeninference` to `darkbloom` with backward compatibility. `56b050b4`
- **Continuous batching** (#110) -- All concurrent requests merged into one batched forward pass per step via `BatchGenerator`. Bit-identical against single-stream greedy. Near-linear throughput scaling (B=4/B=1 = 3.8x on Qwen, 2.9x on Gemma MoE). `56b050b4`
- **Multi-model concurrent serving** (#167) -- `953b8f02`
- **MLXLMServer adoption for OpenAI protocol** (#208) -- `ca8983c4`
- **BatchedEngine migration** (#207) -- `BatchScheduler` migrated from `BatchGenerator` to `BatchedEngine`. `80fc0ee7`
- **Idle-timeout model unload** (#110) -- Provider unloads model after 60 minutes idle (configurable). Next request lazy-reloads. `56b050b4`
- **Persistent Secure Enclave key** (#146) -- Replaces ephemeral CryptoKit SE keys with persistent Security framework keys in the macOS data protection keychain. Bound to signing team's keychain access group. .app bundle with embedded provisioning profile. `56b050b4`
- **Token budget engine-level admission** (#171) -- `BatchScheduler` reports real token budget usage. EWMA decode TPS tracker. Engine-level admission gate rejects with `token_budget_exhausted`. Dynamic token budget sized from model weight bytes and available memory. `78314b4e`
- **Architecture-aware kvBytesPerToken** (#171) -- Computed from config.json metadata (layer count, KV heads, head dim) instead of weight-bytes heuristic. Handles hybrid attention (Gemma 4), GQA/MQA, recurrent layers (Qwen3.5), and VLM wrappers. 4x reduction on Qwen3.5 models. `78314b4e`
- **Rust-to-Swift bridge auto-update** (#110) -- Rust provider auto-updates to Swift bundles, rewrites launchd plist, handles .app bundle layout. `56b050b4`

#### Performance

- Greedy fast-path optimization: `nil` sampler for temperature=0 uses vectorized fallback (+6-13% decode TPS). `56b050b4`
- mlx-swift-lm double buffering, UInt32 token tensors. `56b050b4`
- Release-mode BatchGenerator B=4 matches mlx_lm Python reference (Qwen: ~1130 vs 1119 tok/s; Gemma: ~186 vs 181 tok/s). `56b050b4`

---

### Console UI

- **Refresh earn calculator and landing page** (#185) -- `ed6d655e`
- **Fix Next.js version vulnerability** (#172) -- `2f65bb41`
- **Analytics tracking fix** -- `f7dab6fa`

---

### Testbed / E2E

- **Integration test suite** (#136) -- 12 E2E tests with real Swift provider (Postgres + coordinator + provider per test). Tests: NonStreaming, Streaming, Concurrent, Encryption, Billing, Payout, Referral, InsufficientBalance, InvalidModel, AttestationHeaders. `56b050b4`
- **Load generator and profiling** (#136) -- Configurable concurrency, streaming, benchmark CI with PR comment posting. Heavy-load 100-concurrent 10KB benchmark. Latency regression assertions. `56b050b4`
- **Performance test suite** (#110) -- Warm/cold TTFT, encrypted E2E, batched throughput, decode-TPS bracket tests for Qwen 0.6B and Gemma 26B MoE. `56b050b4`

---

### Security

- **Harden release registration and binary hash policy** (#99) -- Release download URL derived from allowlist. `b5dd0488`
- **Harden release workflow protections** (#103) -- `e515244f`
- **Rust-to-Swift cutover hardening** (#110) -- Post-codesign verification of entitlements, provisioning profile validation (team ID, access group, expiration), MLX wheel pinning, prod hard-fail on Swift tests. `56b050b4`
- **STRIDE threat model** (#110) -- 40 threats across 9 trust boundaries. Automated PR review workflow via Claude API. `56b050b4`
- **Typed response structs for OpenAI endpoints** (#166) -- `7fbfa9fc`

---

### Billing

- **Remove deprecated Solana/wallet-based provider payouts** (#178) -- `fe994fc9`

---

### CI / Infrastructure

- **Migrate CI workflows to Blacksmith** (#182) -- `ff8527a4`
- **CI runs on any PR** (#119) -- Not just master/main. `98a3a024`
- **Remove racing deploy-dev-coordinator workflow** (#137) -- Eliminates race condition with Cloud Build. `cf4c0efa`
- **DEV_/PROD_ prefixed repo secrets** -- Environment-scoped R2 + coordinator secrets for release isolation. `56b050b4`
- **Native Postgres fallback for CI** -- Docker/colima replaced with `initdb + postgres` on macOS runners. `56b050b4`
- **Correct version comments for SHA-pinned actions** (#160) -- `85cedc7e`

---

### Housekeeping

- **Remove unused dependencies** (#112) -- `7ccc592f`
- **Remove stale Python integration test** (#109) -- `e6d63a86`
- **Bump mlx-swift and mlx-swift-lm submodules** (#206) -- Re-homed to Layr-Labs forks. `5919dac1`
- **Darkbloom license agreement** (#173) -- `dde67b28`
- **Update README** (#176) -- `7451a473`
