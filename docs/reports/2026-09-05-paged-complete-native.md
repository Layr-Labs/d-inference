# Complete paged checkpoint codec and historical windows

> Last updated: 2026-09-05 · commit `566d5e549`

The native engine can export and restore complete paged checkpoints for Qwen
recurrent state and exact historical attention windows. Private imported pages,
auxiliary state and metadata retain admission ownership through adoption and
retirement. This milestone passes native correctness tests; provider integration
and production capacity policy remain separate release gates.

## Change

Qwen's codec preserves native attention types, recurrent state and normalized
typed MTP history. Import restores only a validated, explicitly captured
prefix and replaces its temporary destination charge atomically with the full
request promise. Capture and import reserve per-buffer allocator bounds and
observe actual backing; target coverage, auxiliary state and transfer scratch
remain separate. Assistant token validation reads the owned contiguous buffer
without making a second full host token array.

Historical attention checkpoints record the ordered loaded layer/owner map,
window geometry, native dtype, query heads and sinks. They retain the first and
latest eligible uniform prefill boundaries. A private window captures the exact
last min(M, W) tokens at M before successor writes can overwrite its ring; full-attention
pages use the existing donor retirement barrier. Import restores absolute M and
window base max(0, M−W) into independent mutable request pages, preserving shared-KV
borrower relationships. Gemma's stateless per-round drafter needs no fabricated
persistent assistant history. Unsupported persistent state remains ineligible.

The captured stream is passed explicitly to allocation and completion work.
Submitted window copies complete before promotion or discard, and successful
or failed owners drain that stream before final backing retirement and refund.
A native evaluation error discards the affected step cohort. Cancellation and
shutdown wait for the existing retirement barrier.

Paged export copies raw evaluated buffer spans directly into bounded provider
Data after its write fence. It removes the export packing kernel, packed native
output and packing scratch. Metadata has an explicit host owner; manifest value
copies retain it, and mapped page records unmap before their charge is released.
No resident prefix payload bank or serving default is enabled by this commit.

## Validation

The final native4 source passes **57 filters, 532 functions and 630 cases**, with
zero failures or skips; its build took 49.01 seconds. Tests include native dtypes,
allocator ownership, exact page adoption, bounded raw export, metadata aliases,
window rollover and independent branches, cold/warm tiny-model restore,
normal Qwen MTP, Gemma MTP/shared-KV regressions, cancellation and shutdown.
Each filter ran in its own process with a nonzero selected-test check.

The source proof verifies 60 owned files, 480 selected native inputs and 1,356
selected dependency inputs before and after execution. The root independently
verified every final payload and source hash, applied the exact 51-path delta
against native `a486a55d032deae001190bf9795ece1cb3d9a609`, and checked the resulting
owned files. Committed native source is
`aafe2069bcdeadef9250530eb511c598649c0355`; dependencies remain Swift
`67153a874b6d8dd0e1ad04c256298eaae8249cd7`, MLX
`30ae65605cca3fa9f9d5548e7f4fee07cd1e267c`, and mlx-c
`3ccef143eaa28658f8d095fdbc8ff0e9049e2449`.

## Preserved failures and corrections

| Attempt | Outcome and correction |
|---|---|
| Native1 | Swift could not infer a descriptor initializer inside nested closures; the initializer now names its existing type explicitly. |
| Native2 | Production source compiled; fixtures needed the required prompt length, an asynchronous bounded semaphore wait and a completion closure evaluated before the assertion macro. |
| Native3 | 53 of 57 filters passed. Three admission oracles omitted physical-minus-nominal overhead; the export fixture exceeded the append segment bound; a cancellation fixture disposed an unbalanced semaphore; historical fixtures advertised 32-token chunks where import requires the 128-token query-block alignment. |
| Native4 | All 57 filters pass. Corrections preserve the strict source guards and ownership assertions. Historical malformed-manifest tests now first prove that the unchanged base manifest is eligible. |

LLDB identifies native3's signal 5 as semaphore disposal in the test fixture.
The corrected one-shot semaphore starts at zero and is signaled once. Export
fixtures append within the existing segment bound while retaining the larger
raw-byte output oracle. Historical fixtures keep multiple window wraps, exact
absolute positions, full request promises and independent branch pages.

## Evidence and remaining gates

The [manifest](evidence/paged-complete-native-2026-09-05/manifest.json)
(SHA-256 `5fcfab62aef9f3d56a9f9926fa4d1e4dfa7ee1dc98d2160e8a6800613ded6c59`) and
[archive](evidence/paged-complete-native-2026-09-05/payloads.tar.gz) preserve
260 verified payloads: all four attempts, exact source/patch/compile
provenance, raw results, LLDB diagnosis and root commit verification. Archive
SHA-256 is `4a75732da9a2207256966f933eb9e0092cfadb8d5a7a2a4851026b73312bf765`. Build products and model weights are excluded.

These are hermetic tiny-model and scoped real-buffer tests. They do not prove
exact GPT-OSS 20B, Qwen 3.6/3.5 35B, Qwen 3.8 27B or Gemma 4 26B serving,
real-model MTP, HTTP tools/vision, repeated B1/B2/B4 latency, co-resident capacity
or signed persistent-key process restart. No speedup is claimed.

Source review also found that provider startup still applies the legacy fixed
pool capacity policy. Its B1 Qwen 35/36 useful-demand limit is below its minimum
pool size, so it can reject explicit paging before inference. The separate
segmented capacity correction and final provider validation must pass before
model results or a default change can be accepted. Allocator foundation evidence
is recorded in [the allocator report](2026-09-05-allocator-footprint.md); current
serving selection remains documented in
[the cache architecture](../architecture/prefix-cache.md#kv-layouts).
