# GLM-5.3-Flash metadata contract

`architecture.json` records immutable upstream configuration, asset hashes and
HTTP-range safetensors-header observations. The selected Vontra candidate also
records completed payload-hash verification and a local provider integrity
manifest identity. It is a public metadata fixture,
not a model registration, native implementation, numeric golden vector or
full-model qualification result.

Source files use `https://huggingface.co/<repository>/resolve/<revision>/<file>`.
Reference-code paths use the recorded GitHub repository and full commit.
All checkpoint sizes include safetensors headers. `mtp_payload_bytes` excludes
headers. Tensor counts include quantization scales and offsets where present.

The preferred complete Q4 candidate preserves all logical source tensor shapes,
including the prediction block. Its model card reports quantization without
retraining or fine-tuning; header coverage cannot verify that claim numerically.
All 54 downloaded files passed upstream hash verification. The existing
`darkbloom-publish hash` command selected 50 integrity-relevant files, and every
emitted digest matched that receipt. This does not publish or register a model,
prove safe full-model loading, or establish numerical quality.
Its embedded chat template differs from the pinned official template, and its
embedding/output matrices are Q4 despite a BF16 claim in its model card. Neither
discrepancy should be silently repaired or treated as parity evidence.

`shipped_artifact` identifies the template in our own
`EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp` artifact as a separate identity. That
template is the official source with its four numeric attribute accesses written
as `[0]` subscripts, because the pinned Swift-Jinja cannot parse the official
spelling. The official hash remains the upstream rendering authority. This entry
records neither an immutable artifact revision nor weight identity, and it does
not publish, register or qualify the artifact.

The rapid-mlx repository contains only an MTP sidecar. The dfp repository has no
prediction block in its actual tensor headers despite its `-mtp` name. The
preferred complete checkpoint already includes MTP, so loading both its embedded
block and the sidecar would duplicate those weights.

`load-footprint.json` is the compact projection of all 43 retained Q4 headers
and raw-snapshot integrity-file sizes at the same revision. It tests checked
LOAD arithmetic without embedding the full tensor-name inventory. The exact
same-directory result is 192,045,833,503 bytes, not a rounded GiB constant.
The optional `GLM53_RAW_HEADER_FIXTURE_DIR` test also runs the production
projection over the retained full header/index fixture; neither test reads
weight payloads or establishes model qualification.
