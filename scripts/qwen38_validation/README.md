# Qwen 3.8 Next (Flash-Next) reproducible validation

> Last updated: 2026-09-15 · reproduction guide; bind each run to its exact source and binary

The HTTP harnesses send synthetic requests to an **existing healthy**, explicitly
configured release CLI. No workstation address, port or credential is embedded.
They do not start/restart a server, execute generated
tool calls or upload a model. The fixed model is the large native Qwen4 artifact
`DarkBloom/Qwen3.8-Flash-Next-Q4-mtp`, not the separate Qwen 3.8 27B model.
Passing these local cells does not qualify a hosted OpenRouter route.

## Prerequisites and identity

Obtain permission for the target and credentials, then configure the approved
HTTP loopback origin (without an API path) and, if authentication is enabled,
an absolute path to its owned mode0600 bearer-key file:

```sh
export QWEN38_VALIDATION_BASE_URL="$APPROVED_VALIDATION_ORIGIN"
export QWEN38_VALIDATION_API_KEY_FILE="$APPROVED_VALIDATION_KEY_FILE"
```

Omit the key-file variable only for an explicitly authorized unauthenticated
fixture. The transport disables proxies and redirects and rejects non-loopback
targets. Never put the key in command arguments or committed examples. Raw run
receipts are private diagnostics; publish only a reviewed, redacted summary.

Read the [candidate reference](../../docs/reference/qwen4-next-support.md)
and [build prerequisites](../../docs/developer/build.md#native-flash-next-candidate).
Before requests, record the exact provider/SDK and nested dependency commits,
dirty diffs, toolchain, invoked binary SHA-256, loaded source-matched metallib,
all runtime bundles, artifact revision/config/index/tokenizer/template and full
payload hashes. Associate the binary with the actual current process/listener;
hashing a different on-disk executable is insufficient. Record only allowlisted,
non-secret server controls, hardware class and `/metrics` with each result;
do not dump the environment, credentials, machine identifiers or private paths.

One heavyweight GPU lane must be exclusively owned. Check for other workers
and live processes even when a chat is paused. Keep required SSD n-gram/PLE
enabled and use the native paged backend. A saved PID, quiet log or timed-out
observation is not permission to restart: poll the same live handle and verify
its terminal state. Do not overwrite a running executable or another run's
outputs. Each `--output` directory must be new; preserve failures and partial
receipts. `api_matrix.call` cannot recover partial response bytes after a read
exception, so retain server-side diagnostics separately when that occurs.

## Default performance-profile qualification

The current [Qwen4 configuration](../../docs/reference/configuration.md#native-flash-next-candidate)
defaults to full-KV parallel QSA, 32 value partitions and early layer submission.
The earlier dated performance checkpoints retain their historical opt-in scope.
Use three distinct arms: explicit OFF (`DARKBLOOM_QWEN4_QSA_PARALLEL_FULL_KV=0`
and `DARKBLOOM_QWEN4_LAYER_ASYNC=0`), explicit ON (both `1` and
`DARKBLOOM_QWEN4_QSA_PARALLEL_VALUE_PARTITIONS=32`), and all three unset.
An old launcher that omits a variable for OFF is no longer a rollback test.
These model-specific overrides reach foreground/local serving, not the daemon
passthrough allowlist. Native source defaults apply in both modes.

Run `Qwen4PerformanceDefaultsTests` normally. Run SDK
`Qwen4ParallelFullKVParityTests` and `Qwen4LayerSubmissionTests` separately with
`DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST=1` and all three profile variables unset.
Require 504 bit-exact native attention cells with actual dispatch, preserved
wider-prefill fallbacks and deferred-fill/fault/retirement safety. Run actual
selected-checkpoint state/rollback/output-budget tests and the normal full
suites independently; targeted parity is not the full qualification gate.

The provider's `Qwen4DefaultProfilePerformanceTests` uses the same 4,207-token
maintenance-log fixture as the coordinator cache-scope test, with fixed depths
0, 2 and 4. Enable only in the owned GPU lane using
`DARKBLOOM_QWEN4_DEFAULT_PROFILE_PERF=1`, the exclusive flag, both prefix-cache
variables `0`, an approved absolute `DARKBLOOM_QWEN4_REAL_MODEL`, and a new
absolute `DARKBLOOM_QWEN4_DEFAULT_PROFILE_OUTPUT`. It requires the explicitly
selected config/index and actual embedded head, identical target token IDs
and fixed-depth acceptance traces across OFF/ON/unset, plus drained native
owners. Fresh complete artifact hashes are a separate prerequisite.

Record warmup, exact request/tokens, hardware, cache posture and clock for each
benchmark. Internal prefill timing, client time to first token and sustained
decode are different metrics; one-output-token filler probes do not measure
decode. The new profile targets widths 1–6, not large prefill chunks, and does
not establish a 1.5K–2K prefill claim. Existing shape-eligible blocked GDN,
affine QMM and PLE gather defaults remain unchanged. Keep the local API matrices
as the final compatibility gate after native state/cache/media checks.

## Local API matrices

Run these from the provider repository root once with MTP OFF and once with
MTP ON, using separate result directories. Configure MTP in the **server**:
`backend.mtp_mode = "off"` for the target arm, and `"auto"` for embedded MTP;
remove any conflicting MTP-disable override in the ON arm. Keep server
`DARKBLOOM_PREFIX_CACHE=0` for these matched comparisons. Verify actual
`mtp_active`, proposed/accepted counters and `kv_backend_info`; a config value
alone does not prove which path ran. These are correctness fixtures, not
throughput benchmarks.

```sh
python3 -B scripts/qwen38_validation/api_matrix.py --output /absolute/new-api-results
python3 -B scripts/qwen38_validation/responses_matrix.py --output /absolute/new-responses-results
python3 -B scripts/qwen38_validation/reasoning_on_matrix.py --output /absolute/new-reasoning-on-results
python3 -B scripts/qwen38_validation/invalid_reasoning_matrix.py --output /absolute/new-invalid-control-results
python3 -B scripts/qwen38_validation/multi_tool_matrix.py --output /absolute/new-four-tool-results
```

| Script | Cases / assertions |
|---|---|
| `api_matrix.py` | 12 reasoning-OFF API cases: Chat auto/none/required/named tools, stream/nonstream, supported disable aliases, tool-result history and a Responses nonstreaming smoke check |
| `responses_matrix.py` | 10 reasoning-OFF Responses cases: tool choice and function-call/output history, stream/nonstream; native Responses event lifecycle, argument deltas and terminal usage |
| `reasoning_on_matrix.py` | 19 required reasoning-ON cases plus one separately reported unsupported-high probe: visible/reasoning channel separation, tools, actual returned tool-call history, terminals and usage |
| `invalid_reasoning_matrix.py` | 14 cases: eight unsupported-control HTTP 400 refusals before SSE, four OFF/precedence controls, two valid-low recovery requests; bounded error/privacy and observed drain checks |
| `multi_tool_matrix.py` | Four cases per MTP arm: identical four-function request with `required` and `parallel_tool_calls=true`, reasoning OFF/ON and stream/nonstream; require all four names/arguments, distinct call IDs and native tool terminal |

The owned native template accepts reasoning efforts **`low`, `medium`,
`xhigh`**. With reasoning enabled, **`high` and `minimal` must return HTTP 400**;
the optional probe in the reasoning-ON script is not a supported-high pass.
Use the invalid-control matrix for the strict refusal gate.

Chat OFF uses `reasoning.enabled=false` or the supported `effort=none` control;
an explicit disabled Boolean takes precedence over effort. Responses OFF uses
`reasoning: {"effort":"none"}`: the local Responses type does **not** model an
`enabled` field. Do not send `enabled=false` there and assume it disabled
reasoning. The scripts preserve the endpoint-specific contracts and do not
claim hosted adapter fields such as `reasoning_details` or `reasoning.max_tokens`.

The four-call fixture preserves the original request that exposed singular
required-tool prompt wording. Provider `2146f3369a5bb54c04e2b0e537d8d31b8a30c75f`
uses parallel-aware instructions; all eight cells across the two MTP arms
passed on executable SHA-256
`97ad789037350981fa62e749cc1cc72fe38d84cf1cba318ecf89bf49d1f26d8c`.
Keep the earlier one-call failures and the fixed reruns separately. This result
does not cover arbitrary tool counts or silently requalify other changed paths.

## Loaded-model context envelope

`context_envelope_matrix.py` requires an **already loaded** native model with
the requested MTP posture and prefix cache OFF. A healthy listener or a model
listing does not establish that posture. After verifying `/health`, send and
record an explicit small readiness request, its response and the resulting
metrics before the context test. For example, use this nonstreaming body with
at most eight output tokens:

```json
{"model":"DarkBloom/Qwen3.8-Flash-Next-Q4-mtp","messages":[{"role":"user","content":"Reply exactly: ready"}],"temperature":0,"reasoning":{"enabled":false},"max_tokens":8,"stream":false}
```

This warmup performs actual model loading/generation; record it separately.
The later context measurement is **not cold-start qualification**. Confirm
actual paged/MTP/cache metrics and zero active/waiting rows before proceeding.

```sh
python3 -B scripts/qwen38_validation/context_envelope_matrix.py --mtp off --output /absolute/new-context-off
python3 -B scripts/qwen38_validation/context_envelope_matrix.py --mtp on --reference /absolute/new-context-off --output /absolute/new-context-on
```

The second command runs only after the operator prepares the MTP ON server,
repeats the recorded readiness warmup and verifies its actual posture. The
reference must come from the same unchanged harness and exact positive request.
On baseline `02557596`, the positive fixture used 81,057 prompt tokens plus
32 output tokens, with exact OFF/ON output/finish/usage equality. Read actual
usage on each new build; do not infer token counts from repeated text. The
negative fixtures use an oversized prompt and an output reservation of 82,001
tokens **in addition to** its prompt. Both must return HTTP 400 without served
token or MTP counter increases. They do not test successful generation at the
exact 82,000-token ceiling or the original model-card maximum. Requalify this
matrix on a changed executable rather than carrying forward the older pass.

## Complete-cache and lifecycle comparison

First record the long original/suffix reference on the healthy prefix-OFF
server. Then retire that owned server cleanly and prepare the same source,
binary, artifact and sampler with complete cache ON, MTP active, resident cache
OFF and a **new isolated ephemeral** cache root. Set the server's
`DARKBLOOM_PREFIX_CACHE_MEMORY=0`, `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL=1` and
`DARKBLOOM_PREFIX_CACHE_TEST_ROOT` to the unique test directory; ensure the owned
ID's complete-cache default is enabled. This is not signed persistence.

```sh
python3 -B scripts/qwen38_validation/lifecycle_matrix.py --mode reference --output /absolute/new-prefix-off-reference
python3 -B scripts/qwen38_validation/lifecycle_matrix.py --mode cached --media-capability supported --reference /absolute/new-prefix-off-reference --output /absolute/new-prefix-on-results
```

The second command runs only after the operator has prepared and verified the
cache-ON server. The scripts do not perform that transition. Reference mode
records two uncached long requests; cached mode requires matching output,
finish and non-cache usage, cold zero-hit and positive repeat/suffix/readmission
hits, actual paged/cache/ephemeral-key posture, cancellation after streamed
content with bounded native drain, legal HTTP half-close and the explicitly
selected media contract. The full native VLM must use `--media-capability supported`
and return valid HTTP 200 media output without speculation. A separately bound
text-only artifact uses `--media-capability unsupported`, retaining the strict
HTTP 400/privacy refusal gate. Choose from immutable artifact/factory evidence
before requesting; never accept either status based on what the server returns.
Pixel-answer quality remains a separate multimodal gate. Earlier text-only
refusal receipts must not be relabeled as full-VLM qualification.
It does not prove byte-exact full-state restoration, physical SSD reads,
cross-tenant isolation, corruption recovery or persistent restart.

## Separate real-model Swift opt-ins

Prepare the exact testable build and colocate its matching metallib before
running each filter alone. These load the real artifact; do not overlap them
with the HTTP server or another GPU test. A discovered or skipped test is not a
pass. Retain both assertion failures and final exit status.
For the provider fixtures, set both `DARKBLOOM_QWEN4_REAL_MODEL` (fixture identity)
and `DARKBLOOM_QWEN4_MODEL_PATH` (the serving scanner) to the same verified owned
artifact. The inode checks must prove both paths identify the same payload.

The [latest clean-source revalidation](REVALIDATION-20260914.md) records final
reruns, exact artifacts, fixture corrections, speed and unchanged quality limits.
The [earlier private performance checkpoint](PERFORMANCE-QUALIFICATION.md) records the
qualified opt-in paths, exact source/artifact identities, measured speeds,
portable numerical fixtures and still-open quality/release gates. It supersedes
earlier performance totals, not the independent operations and authority gates.

- SDK `Qwen4RealStateTests.testOwnedArtifactStateRollbackReload` compares native
  target logits/KV/QSA/GDN/PLE across retained-width rollback, serialized suffix
  restore and assistant checkpoint history.
- SDK `Qwen4RealStateTests.testOwnedArtifactFinalOutputBudgets` separately
  checks target/MTP final output-budget boundaries. Both require
  `DARKBLOOM_QWEN4_REAL_STATE_TEST=1`, an explicit absolute
  `DARKBLOOM_QWEN4_REAL_MODEL`, `DARKBLOOM_PREFIX_CACHE=0`,
  `DARKBLOOM_PREFIX_CACHE_MEMORY=0` and `DARKBLOOM_QWEN_MTP_MAX_DRAFT=5`.
  The five-draft override is a qualification control; production defaults to
  four. It must not be silently promoted into the HTTP baseline or source.
  See [test methods](../../libs/mlx-swift-lm/Tests/MLXLMTests/Qwen4RealStateTests.swift)
  and [artifact/geometry prerequisites](../../libs/mlx-swift-lm/Tests/MLXLMTests/Qwen4RealStateFixture.swift).
- Provider `FlashNextQuietCancellationReloadLiveTests.cancelsActualPrefillBeforeContentThenReleasesAndReloads`
  requires `DARKBLOOM_FLASH_NEXT_QUIET_LIVE=1`,
  `DARKBLOOM_EXCLUSIVE_NATIVE_GPU_TEST=1`, the explicit owned artifact,
  prefix OFF and active MTP. The [fixture](../../provider-swift/Tests/ProviderCoreTests/FlashNextQuietCancellationReloadLiveTests.swift)
  observes actual quiet prefill, cancels through the production encrypted
  handler, checks drain and weak/native/PLE ownership before reload, then
  compares fresh output. Its signer/tenant and transport sink are injected;
  it is not account authentication, WebSocket or signed-key qualification.
- Provider `FlashNextEncryptedHandlerLiveTests.realModelEncryptsResponseAndRetires`
  requires `DARKBLOOM_FLASH_NEXT_HANDLER_LIVE=1`, the verified artifact and
  prefix OFF. After rebuilding the updated fixture, run the four combinations
  of `DARKBLOOM_FLASH_NEXT_HANDLER_REASONING=off|on` and
  `DARKBLOOM_FLASH_NEXT_HANDLER_MTP=off|auto`, one process at a time.
  Remove conflicting global MTP-disable controls for the AUTO arm.
  The [fixture](../../provider-swift/Tests/ProviderCoreTests/FlashNextEncryptedHandlerLiveTests.swift)
  checks plain text, auto/required/named/none tools and actual returned tool
  history over loopback WebSocket, decrypting received bytes with the synthetic
  consumer key. It checks channel separation, exact tool values, terminals,
  usage and per-request proposal counts. Required/named requests remain
  target-only; the AUTO arm must demonstrate proposals on eligible requests.
  Its authenticated tenant/account/attestation are not production qualifications.
  This is Chat streaming transport coverage, not the full Responses/media matrix.
  Older fixture binaries ignore these new controls: a configuration variable
  alone cannot establish execution of the expanded matrix.

These tools grant no signing, persistent-key creation, production/publication
or upload authority. Each such action requires current explicit human approval.
Keep signed restart, original BF16/A-B provenance, physical
hardware tiers, account/attestation and hosted-route qualification explicit in
the release checklists. Rerun affected cells after source, dependencies,
artifact or numerical configuration changes.
