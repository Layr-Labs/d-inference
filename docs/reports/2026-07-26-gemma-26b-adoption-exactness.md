# Cold-vs-adopted exactness on `gemma-4-26B-A4B-it-qat-4bit`

**Date:** 2026-07-26
**Model:** `mlx-community/gemma-4-26B-A4B-it-qat-4bit` (the production flagship)
**Question:** is prefix-cache ADOPTION byte-exact against a COLD prefill of the
same prompt, and does the answer differ by KV backend?

## Verdict

**26B does NOT reproduce the `gemma-4-e2b-it-4bit` asymmetry. It reproduces the
INVERSE of it.**

On 26B, through the real slot path (coordinator + provider + SSD tier), the
backend whose adoption is INEXACT is **contiguous** — and paged reproduces its
own cold answer byte-for-byte, at both reuse fractions measured (9.9% and
40.1%).

    e2b      paged diverges,      contiguous exact     (test fixture)
    26B      contiguous diverges, paged exact          (production flagship)
    gpt-oss  contiguous diverges, paged exact          (precision excluded by control)

`.auto` resolves contiguous unconditionally
(`EngineV2Factory+Production.swift:570`, `case .auto: resolvedKind = .contiguous`),
and the `.auto` arm reproduced the contiguous divergence exactly. So on this
checkpoint the production default is the inexact arm.

## Route A — e2e slot path (`TestIntegrationExactCacheRouting`)

This is the path on which the original divergence was observed. It exercises
slot-path adoption and the SSD tier.

| arm | resolved backend (heartbeat) | fallback reason | adoption | prompt tok | cached tok | adopted span | reuse | completion tok compared | divergence |
|---|---|---|---|---|---|---|---|---|---|
| explicit `paged` | `kv_backend=paged` | `<nil>` | **PASS** | 28,613 | 28,416 | 2,816 | **9.9%** | 32 vs 32 | none (byte 172 = EOS) |
| explicit `paged`, repeat | `kv_backend=paged` | `<nil>` | **PASS** | 28,613 | 28,416 | 2,816 | **9.9%** | 32 vs 32 | none (byte 172 = EOS) |
| explicit `paged`, thick | `kv_backend=paged` | `<nil>` | **PASS** | 42,913 | 42,752 | 17,152 | **40.1%** | 12 vs 12 | none (byte 84 = EOS) |
| explicit `contiguous` | `kv_backend=contiguous` | `<nil>` | **FAIL** | 28,613 | 28,416 | 2,816 | **9.9%** | 32 cold vs 12 adopted | **byte 4** |
| `.auto` | `kv_backend=contiguous` | `<nil>` | **FAIL** | 28,613 | 28,416 | 2,816 | **9.9%** | 32 cold vs 12 adopted | **byte 4** |
| requested `paged` + `DARKBLOOM_CBV2_PAGED_KV=0` | `kv_backend=contiguous` | `kill_switch` | **FAIL** | 28,613 | 28,416 | 2,816 | **9.9%** | 32 cold vs 12 adopted | **byte 4** |

**3 exact / 3 divergent, and the split is on the RESOLVED backend, 6/6.** The
kill-switch row is the control nobody designed: the operator REQUESTED paged,
the slot resolved contiguous with a named degrade reason, and it diverged with
the other contiguous rows. Requested backend does not predict the outcome;
resolved backend predicts it every time. Any arm read by its request label
would have booked that row as a paged failure.

Every row carries a heartbeat-confirmed `kv_backend` and
`kv_backend_fallback_reason` read off `BackendSlotCapacity` at four sample
points (before-cold, after-cold, after-cold-twin, after-adopted). No arm was
accepted without one.

PASS/FAIL is the adoption assertion
`require.Equal(first.content, second.content)` in
`TestIntegrationExactCacheRouting` (line 249 at HEAD; line 282 under the
uncommitted diagnostic probes these runs used), NOT the overall `go test`
exit. All three paged arms passed it and then failed the later
sidecar-restart check `require.Positive(restored.cachedTokens)`
("exact-cache routing did not reopen after re-preload", line 285 at HEAD),
which is downstream of adoption; the contiguous-resolved arms never reach it
because they abort at the adoption assertion.

### The two strings (thin arms, identical on all three contiguous-resolved rows)

    cold    "The provided text is a repetition of the same sentence: **\"The observatory
             records stable stellar spectra for deterministic archival retrieval.\"**\n\nIf
             you intended to ask a"                                          (32 tokens)

    adopted "The observatory records stable stellar spectra for deterministic archival
             retrieval."                                                     (12 tokens)

On the paged arms cold and adopted are the same string, byte for byte.

This is a crude divergence, not a near-tie argmax flip: it separates at byte 4
and the adopted answer terminates 20 tokens early. Notably the adopted answer
is exactly the answer 26B produces COLD at a longer prompt (42,913 tokens — see
the thick paged row, whose cold output is that same 12-token echo). That is the
shape of an adopted request seeing a materially different context, not of a
numerics wobble.

### Cold-vs-cold determinism (run first, per the brief)

Two cold prefills of the identical prompt, in one process, across two
cache-isolated accounts, on the **paged** arm:

    coldA == coldB : true

Byte-identical on every arm measured (paged thin, paged thick, contiguous,
`.auto`, kill-switch). **26B's cold prefill is deterministic**, so load
sensitivity and run-to-run noise are excluded and every divergence above is
attributable to adoption.

## Route B — `darkbloom benchmark --parity` (in-process `PrefixCacheV2`)

Same binary, same commit. Three runs, `--parity-max-tokens 48`.

| run | pool dtype | prefix tokens | arm | resolved (`probeResolved=`) | matched | adopted span | reuse | adoptionExact / window |
|---|---|---|---|---|---|---|---|---|
| 1 | fp32 | 28,672 | contiguous | `contiguous` | 28,416 | 2,816 | 9.8% | **true / 48 tok** |
| 1 | fp32 | 28,672 | paged | `paged` | 28,416 | 2,816 | 9.8% | **true / 48 tok** |
| 2 | fp16 | 28,672 | contiguous | `contiguous` | 28,416 | 2,816 | 9.8% | **true / 48 tok** |
| 2 | fp16 | 28,672 | paged | `paged` | 28,416 | 2,816 | 9.8% | **true / 48 tok** |
| 3 | fp16 | 53,248 | contiguous | `contiguous` | 52,992 | 27,392 | **51.7%** | **true / 48 tok** |
| 3 | fp16 | 53,248 | paged | `paged` | 52,992 | 27,392 | **51.7%** | **true / 48 tok** |

**Route B cannot see this defect.** Both backends report adoption token-exact,
at 9.8% reuse AND at 51.7% reuse — a thicker adopted span than the e2b arm that
diverged (49.6%). So this is not a thin-sample null: the in-process
`PrefixCacheV2` path does not reproduce the divergence at all. The defect needs
the SSD / slot tier.

That is the operational finding hiding inside a PASS: the adoption oracle added
to the parity harness today is still structurally incapable of observing this
class of bug, because the harness never exercises the tier the bug lives in. It
explains every "adoption exact" reading collected through the harness,
including the retracted 26B one.

`replayBound` was reported as 25,600 on BOTH backends (`25 sliding layers x
1024`), so `adopted = matched - 25,600` throughout.

### Precision control

Run 2 is the genuine perturbation: the process ran at the fp16 default and the
harness's control engine overrode `DARKBLOOM_CBV2_PAGED_KV_DTYPE=float32`, and
the pool was verified to have resolved `float32` before scoring. Verdict:
**TOKEN-EXACT over 111 tokens** (3 prompts, shortest row 15). **On
chat-templated prompts 26B's argmax is NOT precision-sensitive**, which
contradicts the earlier untemplated reading of "2 of 3 rows flip at token 1"
and removes precision as an explanation for anything measured here.

Run 1 had `DARKBLOOM_CBV2_PAGED_KV_DTYPE=float32` exported for the WHOLE
process, so its candidate arm and its control engine were both fp32 and that
"control" is really a second in-process paged cold-vs-cold — also token-exact
over 111 tokens. Runs 1 and 2 produced byte-identical reports in every field,
including the cross-backend first-flip position, so fp16 and fp32 pools give
the same answers on this checkpoint either way you read it.

Cross-backend free-running greedy decode (a separate, weaker signal, scored
UNAVAILABLE by the gate): paged vs contiguous diverge at row 3 token 35,
`9181 vs 5088`, argmax margin `6.141e-02`.

## Provenance

- worktree `/Users/gaj/Documents/Builds/d-inference-paged-kv`, built at
  `d9b27abdf` (chat-templated parity prompts; four later commits are docs/Go
  only and are not in the binary).
- provider binary `provider-swift/.build/release/darkbloom`,
  sha256 `65e9935834af1d018a5020c92c70d5f978f41318f332b9d1c80af612ebde9739`,
  IDENTICAL across every Route A arm.
- `darkbloom runtime-smoke` -> `paged-kernel-runtime-smoke: ok` before any arm,
  so paged was genuinely available and no arm degraded silently.
- weight hash `2468a0cb3049a871`, 30 layers / 25 sliding / `sliding_window=1024`.
- `~/.config/darkbloom/provider.toml` carried no `engine_v2_kv_backend`, so no
  leftover testbed config contaminated the posture of any arm.
- three peer-owned source changes were uncommitted in the tree at build time
  and are therefore IN the binary: `MTPProductionSession.swift` (adds a
  `kvBackend` parameter defaulting to `.auto`), `EngineV2SlotFactory.swift`
  (charges the resolved paged page dtype into `processKVBytesPerToken`), and
  `SSDPrefixCache.swift` (drops `#if DEBUG` from a test-only seam). All three
  are inert here: MTP was UNAVAILABLE on every arm (no `--assistant-model`),
  the slot-factory change is a no-op at the fp16 default and the parity
  harness bypasses `EngineV2SlotFactory` entirely, and the third changes no
  runtime path.

## Is production exposed?

**Yes, but only on the long-context tail — the repo's own figure is 2.3% of
gemma-4 traffic.** Not at p50.

**1. Does a production provider run the SSD tier at all?** Yes, and this is
observed, not inferred. The real (non-testbed) root
`~/Library/Caches/darkbloom/kv3/` on this box holds two per-model directories
created 2026-07-20, and `05e099331e2e` is exactly
`SHA256("mlx-community/gemma-4-26B-A4B-it-qat-4bit")[:12]` (the other,
`6406f7782da4`, is e2b). The testbed cannot have written them:
`DARKBLOOM_PREFIX_CACHE_TEST_ROOT` is honoured only together with
`DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL` and points inside the provider's
`StateDir`. So a production provider built the tier for the flagship against a
real Secure-Enclave-rooted KEK. `SSDPrefixCacheFactory.make` returns nil only
when the KEK or the verified weight hash is unavailable; the ephemeral flag
substitutes the key SOURCE for unsigned builds, it does not enable the tier.

**2. Is the divergence reachable at production prompt lengths?** Not at p50.
The per-donation gate (`SSDPrefixCache.swift:897-899`) is

    prefixTokens > adoptionBoundTokens + minEffectiveTokens
                 = 25,600 + 1,024 = 26,624   (whole-block; documented as 27,136/27,137)

Below that nothing is ever staged, so there is nothing to adopt and nothing
that can diverge. gemma-4's p50 prompt is 979 tokens, 27x under the floor.

But the codebase already quantifies the tail above it: the 27,137 floor
"makes 2.3% of its traffic donatable" (`SSDWindowSidecar.swift:15`, and
`docs/reports/2026-07-25-paged-kv-migration-plan.md:66,264`). **That 2.3% is
donatable, therefore adoptable, therefore exposed**, and both divergent prompt
lengths measured here (28,613 tokens) sit inside it.

Upper edge of the exposed band: donation persists at most
`maxStageBytes / perBlockBytes` blocks, 1 GiB at 20,480 fp16 bytes per token,
i.e. ~52,200 tokens. Empirically a 42,913-token prompt donated and adopted
normally, while a 57,213-token prompt never published a reusable holder inside
the test's 2-minute window (`exact_cache_routing_test.go:201`). The precise
cause of that upper-end failure was not chased and is a separate question.

So: **not an incident at p50, but a live wrong-answer path on roughly 1 in 43
flagship requests**, which returns a different and truncated answer rather than
an error. On contiguous it has presumably behaved this way since prefix caching
shipped; the paged migration is what built the instrument that found it.

## What this does and does not license

- It does **not** overturn the e2b measurement. e2b diverged on paged, 3/3,
  with labelled backends and a ~49.6% adopted span. Both results stand.
- It **does** mean "paged adoption is not exact" is not a property of the paged
  frozen bound. Two of three checkpoints have contiguous as the inexact arm,
  and the two that agree are production and the one model where a precision
  control excludes numerics.
- The `.auto` revert therefore restores the INEXACT backend on the model the
  fleet actually serves. That is not a "did not make it worse" situation on
  26B; it is the wrong default for this checkpoint.
- Whatever is wrong is checkpoint-dependent and lives on the SSD / slot
  adoption path, not on the in-process cache.

## Reproducing

Route B needs nothing but the binary:

    provider-swift/.build/release/darkbloom runtime-smoke          # must print ok
    provider-swift/.build/release/darkbloom benchmark --parity \
      --model mlx-community/gemma-4-26B-A4B-it-qat-4bit \
      --parity-max-tokens 48 --parity-prefix-tokens 53248

Route A needs the model override plus an explicit backend posture. The model
is already a parameter; no source edit is required for it:

    DARKBLOOM_EXACT_CACHE_TEST_MODEL=mlx-community/gemma-4-26B-A4B-it-qat-4bit \
    DARKBLOOM_TESTBED_KV_BACKEND=paged \
    DARKBLOOM_TESTBED_MAX_CONCURRENT=8 \
      go test ./e2e/ -run TestIntegrationExactCacheRouting -v -timeout 45m

Swap `paged` for `contiguous` or `auto`; add `DARKBLOOM_CBV2_PAGED_KV=0`
alongside `paged` for the kill-switch degrade row. Always name
`DARKBLOOM_TESTBED_MAX_CONCURRENT` when naming the backend — selecting a
backend makes the testbed write a TOML, which moves the provider onto its
config-decoder default of 4.

The backend labels and the cold-twin come from a diagnostic probe patch that
is deliberately NOT committed (it prints `kv_backend` /
`kv_backend_fallback_reason` per slot at four points, runs a second cold
prefill through the cache-isolated second account, and reports the byte index
of any cold-vs-adopted divergence). It is preserved at
`/tmp/exact_cache_diag_probes.patch`; the thick-prompt knob added on top of it
is `DARKBLOOM_EXACT_CACHE_PROMPT_THICK=<repeats>` against
`longExactCachePrompt`.
