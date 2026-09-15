# Qwen 3.8 Next performance and stability draft update

> Last updated: 2026-09-15 · commit `28da956a`

This report records the qualified native Qwen4 speed/cache work and native
required-tool framing and scoped mixed-position correction in the draft update. It is engineering-review
evidence, not unconditional model-quality or deployment approval.

## Included changes

- Full-KV parallel QK work retains ordered softmax/PV and native page ownership.
  Early singleton-layer submission resolves deferred PLE fills and preserves
  fault, commit/rollback and retirement ownership. Both master switches remain
  explicit opt-ins; no fleet default or model arithmetic is changed.
- Canonical media-prefix identity omits only a text-position tail proved
  reconstructable on every axis. Media positions, embeddings, kinds, dtype,
  decode delta, tenant scope and native checkpoint checks remain bound.
- `Qwen4NativeToolConstraint` requires native tool framing after the rendered
  reasoning channel and before EOS. Bare function-looking prose cannot satisfy
  required/named choice. Argument values stay opaque/model-generated; schema,
  name and cardinality postvalidation remain mandatory.
- Constrained required/named text calls stay target-only. Ordinary text and
  automatic-tool requests retain MTP eligibility; media stays target-only.
- The later local prompt-removal experiment is excluded because it also needs
  coordinator-sidecar parity, contract-version and vector updates. No blanket
  special-token restriction, argument repair or relaxed oracle is included.

## Original-checkpoint performance

Apple M3 Ultra, 256 GiB; original affine-Q4 artifact, 7,041 prompt tokens and
192 outputs. Native prefill: 897–917 tok/s without cache credit.

| Mode | Prior scheduling | Qualified early submission | Acceptance |
|---|---:|---:|---:|
| Target-only | 27.65–27.70 tok/s | 37.35–37.66 tok/s | N/A |
| MTP depth 2 | 46.28–47.39 tok/s | 59.96–60.06 tok/s | 89.706% |
| MTP depth 4 | 53.30–53.57 tok/s | 64.16–64.22 tok/s | 73.958% |

Paired arms preserve all 192 golden tokens and same-depth proposal/acceptance
traces. Qualification includes 360 bit-exact attention cells, layer-safety and
full-weight state checks, 24 encrypted loopback-WebSocket cases, 14 reference/
18 cached media mechanisms and 9 cached lifecycle checks. These bounded
measurements are not sustained agentic throughput guarantees. Exact scopes:
[clean-source revalidation](../../scripts/qwen38_validation/REVALIDATION-20260914.md).

## Framing runtime and separately selected checkpoint

Assessed framing executable SHA-256:
`5ce3d3ea7b81cb6badb655b36744d38a48f5f73a2c1c370fd40e9672d1d9f1f7`;
metallib: `2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2`.
Publication preserves runtime code while excluding private diagnostic targets.

Both provider validation postures passed: 103 XCTest passes/7 skips and 2,913
Swift Testing pass records/53 skips each. Ten entitlement early returns remain
unqualified. SDK postures passed 875 XCTest tests/9 skips and 1,209 Swift Testing
tests/14 skips each. These are validation-source results, not a claim that fresh
public recursive CI or all opt-ins passed.

The separately selected checkpoint has 21 shards/3,748 indexed entries, 76
embedded-MTP entries, 333 BF16 vision entries and 384 PLE entries/128 parts.
Weights total 106,294,664,646 bytes (+1,644,824,456 bytes). Global 4-bit storage
has selected 5/6/8-bit modules; it is not uniform Q4 or BF16-equivalent.
Config: `319b334a1abb705acf06035aa0331bcb7c25976ff93a5035b543548738a10824`.

Each MTP OFF/AUTO configuration passed 59 local OpenRouter-compatible cells
plus 24 string-tool/real-generated-ID history cells, covering reasoning OFF/ON
and streaming/nonstreaming Chat/Responses. The four-call non-reasoning failure
was fixed. The 81K context and uncached lifecycle checks passed.
Matched 7,041/192 client decode proxies: 31.76/32.48 tok/s OFF and 54.02/49.34
AUTO, with 87.8%/84.2% acceptance. They are not the native original-target table.

## Mixed text/media position correction

The updated SDK preserves absent versus explicit request positions when mixed
text/image rows are packed into a rectangular tensor. Text filler ramps no
longer select the explicit media rotary path. Genuine media planes remain
intact even when their values coincide. The binding covers ordinary forwards
and direct MTP hidden-returning seed/decode/prefill/verification, including
history maintenance while batch pressure forces speculative depth to zero.
No weight, tokenizer, quantization, head, cache-format or sampler change is
included. Other architectures and singleton forwarding retain their paths.

Assessed correction executable SHA-256:
`16e4c23ed2e2691f207977d64acf294d950b887c46c67c37840b1df676333544`.
The metallib and selected checkpoint config above are unchanged. SDK library/
test source equivalence to the public packaging was checked; retained license
and layer-description comments differ, not runtime code. Public SDK pin:
`f3f0b235c4e98c9c8e9f3cd76b4ec1752c27960b`.

- Release builds and 43 targeted tests passed: seven XCTest position/policy/
  PLE tests and 36 stateful-MTP integration tests, zero failures/skips. Actual
  EngineV2 route spies exercise ordinary and hidden-returning mixed forwards.
- MTP OFF/cache ON and MTP AUTO/cache OFF each passed 11 unchanged real-model
  HTTP/lifecycle waves: six serial controls, two mixed B4 waves, simultaneous
  images, cancellation with live mixed peers and post-cancel text. Each arm
  completed 19 responses and one cancellation. Content, reasoning, arguments,
  finish and prompt/completion/total usage match original isolated references.
- Both arms observed native B4, not merely queued clients. AUTO's singleton
  control proposed 238 draft tokens; OFF proposed zero. This does not claim
  batched speculation: native Qwen4 retains its one-row speculative cap.
- A separate 6,788-token long-prefix batching mismatch already reproduces on
  the preceding runtime, including cache-disabled B2 and reversed B2. Its
  failing output is identical before/after the first position correction.
  Cache-enabled long-pair/warm controls also fail exactness. These original
  failures remain open; no long-prefix cure is attributed to this patch.

These are scoped position-regression results, not a fresh full-suite run, a
full cache-by-MTP matrix, raw-logit/state proof, long-context concurrency or
hosted qualification. Default admission remains one active generation row;
`DARKBLOOM_QWEN4_BATCHED_QSA=1` remains an unqualified opt-in for broader serving.

## Open gates and rollback

- Original strict fidelity on the published framing runtime: 8/20 exact passes,
  16/20 wire passes, and two additional NFC-only equivalent values per mode.
  Literal copying and reasoning-ON refusal/stream failures remain disclosed.
  Later local prompt results are not attributed to the published code.
- Multimodal answer quality: 16/19 pass; brief-event recognition, an interleaved
  media-tool value and its dependent real-history case remain failures.
- New-target native MTP/state, affected cache/transport, physical hardware,
  BF16 equivalence, signed persistence/trust and hosted routing need separate
  evidence. Local compatibility is not hosted OpenRouter certification.
- Long-prefix concurrent/cached exactness and the full affected-suite rerun
  remain open; the scoped mixed-position pass does not close these gates.
- [ ] All required end-to-end release gates complete, with current evidence.

Disable the performance switches to restore prior scheduling/attention dispatch.
Roll back paired SDK/provider pins together and retain the previous immutable
model revision. Public model visibility, R2, merge, signing, registry activation
and deployment are not side effects of this draft update.
