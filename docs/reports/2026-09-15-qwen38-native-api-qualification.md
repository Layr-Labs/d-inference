# Qwen 3.8 Next native API and cache qualification

> Last updated: 2026-09-15 · commit `2a843bb2c`

The reviewed Qwen 3.8 Next (Flash-Next) candidate preserves native Qwen4,
multimodal assets, embedded MTP, paged storage, prefix caching and SSD PLE
offload. This update closes demonstrated prompt/framing and API/accounting
defects and records the completed regression work. It does not claim that
every model-quality, multirow or deployment gate passed.

## Corrections included

- Native required/named Qwen4 text calls retain the original messages and
  trained template. Named choice filters declarations; native framing and
  final name/schema/cardinality validation remain authoritative. Swift, Rust
  and Go use the synchronized normalization-v5 contract; older contracts fail
  cold instead of reusing incompatible prefix proofs.
- Each constrained tool frame requires a declared native function opening or
  framed JSON after its tool opener. Argument values remain opaque and
  model-generated. No fabricated arguments, tag stripping, heuristic
  unescaping, repaired closing text or weakened oracle is included.
- Coordinator-added terminal events preserve the original response ID and
  creation time. Responses report authoritative usage totals and mark
  finalized reasoning items completed while preserving a truncated root
  response's incomplete status.
- Combined finish-plus-usage Chat events retain validated cached-token and
  reasoning-token details. A separate usage event takes precedence; absent
  usage is not invented and details are not duplicated. Provider payloads,
  signatures, hashes, content and token totals remain intact.
- Source-relocation fixtures, complete artifact manifests and catalog hash
  bindings are corrected without relaxing original test inputs or verdicts.
  The reviewed upstream provider/coordinator refactor integration is retained.

Implementation: `provider-swift/Sources/ProviderCore/Inference/Prompting/ToolChoicePromptPolicy.swift`,
`provider-swift/Sources/ProviderCore/Inference/Qwen4NativeToolConstraint.swift`,
`coordinator/promptsidecar/src/normalize.rs`, `coordinator/api/consumer_stream.go`
and `coordinator/api/responses_response.go`. API contracts and reproduction steps live
in [API contracts](../reference/api-contracts.md),
[native Qwen4 support](../reference/qwen4-next-support.md) and
[testing](../developer/test.md).

## Source and artifact binding

The assessed native executable has SHA-256
`e092f806305dbd9fe91e3558343dfbc9e5871f0b9d7eb3c6ea5ed437c0b264a3`;
the metallib has SHA-256
`2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2`.
Publication checks preserve the assessed native and coordinator source trees.
The companion SDK artifact-profile additions affect tests/documentation only;
its production libraries and package definition are unchanged from the
previous public SDK pin. A public CI build has its own binary identity.

The unchanged selected artifact is native `qwen4_exp` / `qwen4_exp_text`:
21 shards, 3,748 indexed arrays, 76 embedded MTP entries, 333 BF16 vision
entries and 384 PLE entries in 128 parts; 106,294,664,646 weight-file bytes.
Config SHA-256:
`319b334a1abb705acf06035aa0331bcb7c25976ff93a5035b543548738a10824`.
It retains its declared predominantly 4-bit/group-64 and selected 5/6/8-bit
storage. No conversion, re-quantization or BF16-equivalence claim is made.

## Completed checks and retained limits

| Gate | Observed result | Scope boundary |
|---|---|---|
| Final local OpenRouter-style core | 118/118 required cells pass across MTP OFF/AUTO; reasoning OFF/ON, tools/history and supported Chat/Responses stream/plain surfaces | Two unsupported-effort observations recorded separately; local, not hosted certification |
| Extended API matrix | 138 declared cases, no new regressions; 48 weather/history passes and 52 strict-fidelity/held-out wire passes | Exact argument values and visual answer quality remain separate |
| Real account-scoped cache | 16/16 pass, including all eight previously missing HTTP cache-detail cases; actual 4,096-token SSD reuse and sidecar recovery | One provider, two synthetic accounts, ephemeral key; not provider-process restart or signed persistence |
| Default long-prefix cache | 24 waves/32 responses pass across both MTP/cache modes, including queued/reversed requests and 6,144-token warm reuse | Native maximum active row count is one |
| Coordinator regression | 5,876 pass events, zero failures, three skips; race suite 4,760 pass events, zero failures, three skips | Local opt-ins pass separately; live APNs remains unqualified |
| Provider full suites | Per posture: 120 XCTest passes/7 skips; 2,917 Swift Testing pass records/52 skips; zero failures | Ten entitlement early returns are not qualified passes |
| SDK full suites | Per posture: 891 XCTest tests/9 skips; 1,210 Swift Testing pass records/14 skips; zero failures | Aggregate framework counts are not unique pass totals |
| Native/state/resource checks | 25 selected-target retained/rejected state/logit cases and budgets 1–9; 33 additional invocations include 360 full-KV exactness cells, PLE, memory, vision and lifecycle checks | Broader long-context/cohort and physical-tier claims remain separate |
| Media-cache and transport | 14 reference/18 cached media mechanisms, nine cached lifecycle checks, six mmap checks and 24 encrypted loopback handler cells pass | Injected identities and simulated memory tiers do not establish production trust or hardware support |

For each MTP mode, strict fidelity remains 13/20 exact and 20/20 wire-valid,
with two additional NFC-equivalent values; held-out cases remain 3/6 exact
and 6/6 wire-valid. Multimodal answer quality remains 16/19. Literal-copy,
brief-video and dependent media/tool-history failures are retained. The native
tokenizer's NFC contract is unchanged; neither quantization nor engine/model
attribution is conclusively excluded by these failures.

The existing multirow opt-in recheck records 74 waves: 58 pass and 16 fail.
Short mixed/media/cancellation cases witness native B4; long-prefix pair/replay
exactness remains failed. The default queued profile passes and remains one
active native row. No safety cap, default or numerical fingerprint is changed
to claim that multirow is qualified.

## Matched speed check

On the same M3 Ultra 256 GiB, 36 matched requests cover nine fixed text/image/
code cases across the prior/candidate builds and MTP OFF/AUTO. Requests,
outputs, finishes and token counts match. Candidate/prior wall-time ratios are
0.971784–1.008637: no meaningful new slowdown in this bounded workload.
The approximately 7K-prompt/192-output code cases report client decode proxies
of 32.25–32.43 tok/s OFF and 50.49–52.67 tok/s AUTO. These are not native
prefill/decode clocks or sustained agent-traffic certification.

The original-artifact native fixed-depth performance table remains in the
[earlier performance report](2026-09-15-qwen38-performance-stability.md).
Do not transfer its absolute rates to the separately selected checkpoint.

## Review and release boundary

The human local validation passed. The reviewed updates are authorized for
the existing SDK/provider PRs; this does not waive the failures above or
authorize a merge, model publication, registry activation or deployment.
Physical tiers, original BF16 comparison, signed persistence/account trust,
hosted routing and operational release checks need their own resources and
evidence. Final CI results attach to the new public heads, separately from
the completed source-bound local qualification.

- [ ] All required end-to-end release gates complete, with current evidence.

Preserve paired dependency pins and the previous immutable model when rolling
back. After an approved SDK merge, repin the provider to the observed merged
SHA and recheck integration. Do not publish credentials, real developer
endpoints, raw prompts, token/logit dumps or media diagnostics with receipts.
