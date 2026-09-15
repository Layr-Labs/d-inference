# Pinned Qwen3.8 Flash-Next conversion tools

Private support candidate, September 11, 2026. These tools do not download,
upload, publish, register or deploy a model. They enforce the official source
`Qwen/Qwen3.8-Flash-Next` revision
`de4b8e4d43b917e7706784d8bb445c9af86a3540` and produce new evidence only.
They do not retroactively authenticate an older conversion.

## Source and conversion contract

- All ten pinned metadata files, exact source index/shard inventory and cached
  source revision must match. Every shard needs a valid expected SHA-256.
- Metadata-only verification explicitly does not verify payloads. Full
  verification hashes all 131 source shards, with no successful partial coverage.
- Conversion verifies each source payload before quantization and records every
  source/output shard digest, MLX runtime identity, output config/index/metadata
  hashes and a digest of the complete manifest.
- Every original tensor identity must be represented by its unchanged key or a
  complete weight/scale/bias triple. All 31 original MTP identities are preserved;
  missing, extra or colliding output identities fail before a success receipt.
- Quantization is affine Q4/g64 with BF16 scales/biases and g32 exceptions for
  compatible last dimensions such as the 160-wide n-gram table. This is Q4,
  not oQ4e, and is not numerically identical to the original BF16 model.
- PLE remains 128 separate packed table parts. The converter does not concatenate
  the full table or strip embedded MTP. It may retain vision tensors; the native
  provider's text-only serving policy is a separate capability gate.
- Output must be a new directory under existing, verified available storage.
  Neither entry point creates a missing source mount or overwrites a receipt.

## Usage

Run from this directory or invoke the scripts by their full paths. Substitute
existing, verified local storage paths; a placeholder is not a mount check.

```sh
python3 -B verify_qwen38_download.py --source /path/to/pinned-bf16
python3 -B verify_qwen38_download.py --source /path/to/pinned-bf16 --hash-shards --output-manifest /path/to/new-source-receipt.json
python3 -B convert_qwen4exp_q4_mtp.py --source /path/to/pinned-bf16 --output /path/to/new-q4-output
```

The converter requires a separately identified MLX installation and enough free
space. Full hashing and conversion are expensive; coordinate storage and GPU
ownership first. Download-cache expectations are local Hub metadata, not an
independent online authentication of the source. Preserve the resulting receipts
and reconcile with trusted source/revision evidence before release review.

## Tests and qualification limits

```sh
python3 -B -m unittest -v test_qwen38_provenance
```

The 30 synthetic tests cover pinned identity, complete hash coverage, missing or
corrupt files, strict CLI behavior, MTP/output-key completeness, manifest
integrity and receipt preservation. Converter integration uses a stub quantizer
and serializer; it does not import real MLX, execute tensors or qualify numerical
conversion correctness.

Real source payload verification, independent A/B conversion equality,
final-artifact integrity, native embedded-MTP activation, exact SSD row gathers
and same-binary paging/cache/restart tests remain independent acceptance gates.
Licensing and release/publication approval are separate owner decisions.
