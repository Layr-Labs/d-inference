# Qwen3.8 Flash-Next R2 chunk publication

> Last updated: 2026-09-16 · commit `0f7b1e611`

The selected Hugging Face model was packaged and uploaded as separate cacheable
R2 objects. A complete 480 MB chunk was downloaded through the public CDN with
a matching SHA-256 and `CF-Cache-Status: HIT`. This report records artifact and
transport verification; it does not qualify inference or activate the model.

## Immutable artifact

| Field | Value |
|---|---|
| Model | `EigenLabs/Qwen3.8-Flash-Next-MLX-4bit-mtp` |
| HF revision | `e555958420096f695d449111693a6647b698479b` |
| Version | `2026-09-15-r2chunks-e5559584` |
| R2 bucket | `darkbloom-models` |
| R2 prefix | `v2/EigenLabs-Qwen3.8-Flash-Next-MLX-4bit-mtp--efc2f1cba457/2026-09-15-r2chunks-e5559584` |
| Original runtime files | 31, including 21 safetensors shards |
| Original runtime bytes | 106318166173 |
| Transport objects | 228 weight chunks, 10 auxiliary files, one manifest |
| Maximum chunk size | 480000000 bytes |
| Aggregate SHA-256 | `da1209196c29bad9faad2525a85714ccf824600eac36097c1099e3ad2baf6ba6` |
| Manifest SHA-256 | `5f5bd9f559ae40e81bf4fe21d41757ff9ad1928793e1dd3e567244f640a9534d` |
| Upload completed | 2026-09-16 05:00 UTC |

[Published manifest](https://models.darkbloom.ai/v2/EigenLabs-Qwen3.8-Flash-Next-MLX-4bit-mtp--efc2f1cba457/2026-09-15-r2chunks-e5559584/manifest.json).

## Verification performed

1. Every runtime file matched the source repository's published SHA-256 and size.
2. Each packaged chunk was read back and hashed; ordered reconstruction matched
   each original file hash. Paths, safetensors layout, tokenizer/configuration,
   embedded MTP weights and the original aggregate hash were preserved.
3. All 239 uploaded objects matched local size and single-PUT MD5/ETag, with
   server-validated Content-MD5 and retained SHA-256 metadata. The manifest was
   uploaded last, after data verification; final remote inventory matched.
4. The public manifest download matched the local manifest byte-for-byte.
5. A full GET of `model-00001-of-00021.safetensors.chunks/000002.bin` at
   2026-09-16 04:17 UTC returned 480000000 bytes, `CF-Cache-Status: HIT`, `Age: 114`,
   and `Cache-Control: public, max-age=31536000, immutable`. Its SHA-256 was
   `166c81d2acbce232155e6b68b53bd274bce51b7cc4377eb9a963bde463db4e8d`, matching
   the published manifest. This proves one warmed edge response, not residency
   of every chunk in every region or a guarantee against later eviction.

## Integration boundary

The original configuration declares `qwen4_exp`; transport does not rename it or
substitute another architecture. Native inference is a prerequisite tracked in
[provider PR #1030](https://github.com/Layr-Labs/d-inference/pull/1030) and
[MLX SDK PR #149](https://github.com/Layr-Labs/mlx-swift-lm/pull/149).
No inference run, coordinator deployment, provider release, model registration,
promotion or alias change was performed for this publication.

For staged registration, R2 source selection, capability gating and rollback,
follow [the chunk publishing runbook](../operations/model-r2-chunks.md).
