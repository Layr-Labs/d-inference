# Gemma 4 26B QAT's lattice revision on two-Mac pairs

> Last updated: 2026-11-15

This record is the evidence document of Gemma 4 26B QAT's entry in the
provider's public cluster model declaration (`ClusterPublicModels`,
`gemmaQATLattice`): that entry's `evidenceSHA256` is the SHA-256 of this file,
and every release's cluster runtime facts name it for Gemma's grant and parity
qualifications. The owner's declaration of the model itself (2026-11-03, both
mode families) is in [Public cluster models](2026-10-31-public-cluster-models.md);
this file covers the artifact the declaration now names. It contains no
endpoint, credential, machine identifier or personal workspace location. It is
not a hosted-provider certification or a production deployment approval.

## Why

On 2026-11-14 the production catalog moved `gemma-4-26b-qat-4bit` from
`2026-06-08-r1` to the QAT lattice revision `2026-11-13-qat-lattice8-r1`
("Gemma C"). The cluster runtime registered only the earlier build, so 0.10.13
left Gemma out of its pair facts, and no pair could serve the build the catalog
offers. 0.10.14 registers C in its place (one artifact per catalog entry, which
every closed list of the runtime and its tools pins).

## The artifact

| Field | Value |
|---|---|
| Catalog model, revision | `gemma-4-26b-qat-4bit`, `2026-11-13-qat-lattice8-r1` |
| Model CDN prefix | `v2/gemma-4-26b-qat-4bit--69619d858022/2026-11-13-qat-lattice8-r1` |
| Aggregate (catalog `weight_hash`) | `6aee23b20b8adfe05a4fdf2c13fdd0959de379dd3ddeff9497c717c8a92a1e5e` |
| `manifest.json` (CDN bytes the worker pins) | `f300d38f819172bd57464fd158d1ee77a322b7da8a327dd1b5a646d9471a36ee`, 11 files, 17,994,477,744 bytes |
| `config.json` | `904fb35a8a6b06c1634daf194f8d9b0e24fd6c433caaa1a42da72a34e2505ddc` |
| Text tensors | 1,339 (`language_model.`), 16,819,251,260 bytes, largest 738,197,504; inventory `831c84977e2c110118ba641da688e09de7eeb41e24ec715b54fe28622351bc6f` |

The values were read from the artifact's own `config.json`, `manifest.json` and
safetensors headers on the model CDN (headers only), and are the registered row
(`Gemma4RegisteredSpecification`). The earlier build was aggregate
`2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785`.

## What is different about it

Its quantization table names every projection (327 entries): the routed
experts keep the QAT checkpoint's 4-bit lattice in groups of 32; attention, the
dense feed-forward, the router, the tied embedding and the vision embedding are
8-bit in groups of 64. The earlier build was 4-bit in groups of 64 with only the
dense feed-forward and router at 8 bits. The runtime now holds each row's table
entry by entry (`Gemma4QuantizationLayout`), sizes each pipeline stage from it,
and cuts each tensor-parallel tensor at its own bits and group size. Both
tensor-parallel channel splits still widen to the table's groups of 64, the unit
the SDK builds a rank's local widths in, so the experts split as 384 and 384
channels (one shared group, zero rows), and a rank holds 9,465,661,500 bytes.

## Qualification on a pair

DevNet pair-2: an M3 Ultra (rank 0, macOS 27.2) and an M5 Max (rank 1, macOS
27.0) over one Thunderbolt 5 cable, guarded JACCL, on 2026-11-15. Tools built
from the change (`darkbloom-cluster-worker`, `-reference`, `-pair-check`, Metal
library `5b97893c…`). C was placed on both Macs by hand from the model CDN and
checked file by file against the manifest (the DevNet catalog still listed the
earlier build, so the catalog's download path was not exercised). Each record
compares the pair with both Macs' own single-Mac references at the same cut,
under the mixed-chip rule of 2026-10-09 (tokens equal, or a first difference at
a near tie).

| Record | Mode | Cut | Prompt / output tokens | vs M3 Ultra reference | vs M5 Max reference | Passed |
|---|---|---|---|---|---|---|
| `pipe-p4k-cut15` | `pipeline_v1` | 15 | 4,096 / 64 | `divergedAtNearTie` (15) | `tokensEqualLogitsDiffer` | yes |
| `pipe-short-cut15` | `pipeline_v1` | 15 | 32 / 64 | `tokensEqualLogitsDiffer` | `diverged` (42) | no |
| `pipe-p4k-cut18` | `pipeline_v1` | 18 | 4,096 / 64 | `tokensEqualLogitsDiffer` | `diverged` (15) | no |
| `pipe-short-cut18` | `pipeline_v1` | 18 | 32 / 64 | `tokensEqualLogitsDiffer` | `diverged` (42) | no |

Every pipeline run completed its 64 tokens with both ranks agreeing. The two
Macs' own references differ from each other on the same request, so a pair that
equals one Mac's reference token for token can fail against the other's, as the
earlier build's records on this pair did (three of seven not passed). The four
records are bundled as written
(`DistributedInstalledPairQualificationRecords`); the earlier build's seven are
removed. What they decide:

- A release lists the model in its facts: it has a passed record
  (`ClusterRuntimeApprovalFacts.releaseModels`).
- They grant no mode family of their own: the one pass is contradicted by the
  32-token request's divergence at the same shape (M3 Ultra then M5 Max, cut
  15, pipeline), so `ClusterPairServingDecisions` withholds the model. Its
  public family is the declaration's alone, as the release facts state it:
  the pipeline. The owner declared pipeline and tensor parallel for the
  earlier build on 2026-11-03; this revision's tensor parallel serves pairs for
  their owner until it has run on a pair, and the owner decides whether it is
  declared (the 0.10.14 release plan's question).
- A pair is steered away from the shapes that diverged: an M3 Ultra leading an
  M5 Max is not planned in a pipeline cut at 15 or 18; other cuts, the other
  order, other chips and tensor parallel are.
- The declaration's evidence placement stays nominal (two M5 Ultras, the
  owner's rule of 2026-11-03 that a declared family applies on any Apple
  silicon pair); this revision's own evidence is the M3 Ultra and M5 Max above.

Tensor parallel did not load on the first run: the split cut the experts in
groups of 32 (352 channels a rank) while the SDK builds a rank with 384, and
rank 1 refused the load. The split was changed to the SDK's unit (above), and a
test now holds the plan's local widths to the SDK's for both QAT tables. A
tensor-parallel run is not recorded (`darkbloom-cluster-pair-check record`
takes pipeline runs); its runs on the pair with the corrected worker, and the
product's on a DevNet build, are reported with the change, not here. Only
serial prefill ran; the one-chunk lookahead (schedule 2) is declared as for the
other models.

## Offline checks

- The registered row matches C's fixtures (the CDN's `config.json` and
  `manifest.json` bytes) and the expected inventory written out from the
  quantization table; each stage's mappings and bytes at cuts 12 and 15
  (`ResidentAdmissionGemma4Tests`).
- The tensor-parallel plan covers C's 1,697 stored tensors from its real headers
  (358 vision tensors skipped) and its local widths equal the SDK's; synthetic
  two-rank runs with the lattice table equal the single-process oracle bit for
  bit (`Gemma4TensorParallelTests`).
- The placement layout from C's real headers equals its golden layout, with
  routed experts 8 of 128 over 14,273,740,800 bytes (12,976,128,000 divided)
  and a decode step reading 3,437,619,260 bytes (`PlacementChecks`).
- The worker describes C and refuses the earlier build (`--describe-runtime`).

## Production

The fleet reads the catalog row `gemma-4-26b-qat-4bit` (revision
`2026-11-13-qat-lattice8-r1`, `weight_hash` `6aee23b2…`) and downloads its
manifest from the model CDN prefix above; a pair's worker pins those manifest
bytes. A release registers C's facts as part of its normal registration, and
the coordinator derives C's pair approvals from them. Nothing else changes in
production. A catalog rollback of Gemma to the earlier build would leave Gemma
unservable on 0.10.14 pairs until a release registers that build again; a pair
set up with the earlier build is set up again on C.

## Limits

- One pair of mixed chips; no M5 Ultra pair and no pair formed by the
  coordinator ran C. Its tensor-parallel batch lanes (two, the earlier build's
  qualified width) were not run with this revision's 8-bit and 4/32 kernels.
- The tensor-parallel fastest-plan rule is checked on constructed Macs with
  this revision's layout; its rank no longer fits two 24 GB Macs (32 GB do).
- The DevNet catalog lists the earlier build, so the catalog-driven download
  was not exercised; C was placed by hand.
