# Gemma and GPT-OSS native KV lossless samples

> Last updated: 2026-10-09

The production byte-plane/LZ4 codec reduces these actual Gemma 4 native KV
samples by **13.01%** and GPT-OSS 20B samples by **7.73%**, with every restored
byte identical. These are short public artificial inputs at 32 and 33 tokens.
They establish compressibility of the captured packets, not long-context
capacity, inference quality, encrypted restore throughput or packed INT4 gains.

## Capture and identity

The probe consumes 32 deterministic artificial token IDs with seed `FACE`,
then performs one genuine greedy decode. It evaluates and copies native cache
arrays at both positions, with a four-MiB aggregate host-payload bound per model
and a one-MiB bound per array. The inputs contain no consumer prompts.

Gemma captures all five full-attention owners (layers 5, 11, 17, 23 and 29)
and one sliding-window owner (layer 0), using BF16 K/V. GPT-OSS captures its
first sliding owner (layer 0, BF16) and full-attention owner (layer 1, FP32).
The selected layers are a bounded sample rather than a complete model dump.

The model identities were computed with the canonical `darkbloom-publish`
weight-hash path:

| Model artifact | Aggregate SHA-256 | Configuration SHA-256 |
|---|---|---|
| Gemma 4 26B QAT 4-bit weights | `2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785` | `29910322dd085f45c8f95c6c0f1611b20f722d6f6c8394321b34817e98a972fa` |
| GPT-OSS 20B weights | `61bfc04e4016a7fa487eb10e29f79360047e302487229f298da3681984aec512` | `d1c1f73bf62116ed0bb37c068af80534543cd1de9b61d609fc01bf70920e842d` |

Quantized model weights do not make these cache payloads INT4. The receipts
record each native dtype, shape, layer, phase and byte digest. The probe uses
SDK base `b40f465e9d9a3bccd5760e95858a2cc8f013acd7` with only a benchmark
executable and its package declaration added. Its original sources and package
diff are preserved under
[`original-probe/`](evidence/native-kv-lossless-2026-10-09/original-probe/).

## Codec results

Compile the actual production `SSDLosslessChunkCodec.swift` with Apple Swift
6.4 and `-O`, alongside [the driver](evidence/native-kv-lossless-2026-10-09/main.swift).
The driver supplies only the codec error contract, applies the production
four-MiB segment bound, and checks five encode/decode repetitions per packet.
BF16 uses two byte planes; FP32 uses four. Every repetition must restore all
native bytes exactly.

| Model | K/V packets | Native bytes | Framed encoded bytes | Reduction |
|---|---:|---:|---:|---:|
| Gemma 4 | 24 | 1,863,680 | 1,621,177 | 13.01% |
| GPT-OSS 20B | 8 | 399,360 | 368,498 | 7.73% |

The encoded count includes the codec's two-byte frames. It excludes DBK3
metadata, AES-GCM tags and filesystem allocation. All 32 packet results are
bit-exact. The source SHA-256 is
`6bf3651d010bb5ac0c1886673f97a85580fcd35c6d6e816d40234ebcff501a98`.
Frozen [results](evidence/native-kv-lossless-2026-10-09/results.json),
[summary](evidence/native-kv-lossless-2026-10-09/summary.json) and
[codec provenance](evidence/native-kv-lossless-2026-10-09/codec-manifest.json)
retain the measurements and source/binary digests. Timing samples are retained
for audit; this report makes no timing claim.

The earlier [Qwen packet measurement](2026-10-09-lossless-checkpoint-codec.md)
saved 26.76%. Its different result reinforces that content and dtype determine
compressibility. None of these samples supplies a universal saving factor.

## Reproduction and limits

The deterministic [input archive](evidence/native-kv-lossless-2026-10-09/native-inputs.zip)
preserves model receipts, model manifests, native K/V and the five Gemma gamma
arrays. [The input manifest](evidence/native-kv-lossless-2026-10-09/input-manifest.json)
binds every member's name, byte count and SHA-256. Gamma arrays support the
separate native-basis relation audit; they are excluded from the codec totals.
The archived probe is sufficient to inspect the capture path without model
weights. Replaying the codec needs only macOS, Swift and the small archive.

From the repository root, build and replay into a new output directory:

```bash
EVIDENCE=docs/reports/evidence/native-kv-lossless-2026-10-09
python3 "$EVIDENCE/run.py" \
  --build-codec-source provider-swift/Sources/ProviderCore/KVCacheSSD/SSDLosslessChunkCodec.swift \
  --input-archive "$EVIDENCE/native-inputs.zip" \
  --output /tmp/native-kv-codec-replay
```

The replay verifies the codec and driver source hashes, compiles them itself
with `/usr/bin/swiftc -O`, validates the archive inventory and member digests,
then compares the new byte totals with the frozen summary. It records the
fresh binary and compiler provenance, since rebuilding a Mach-O executable
need not reproduce the archived binary digest. The original timing samples
and results remain intact. A strict `--codec-binary` mode also accepts the
original measured executable if its recorded hash matches.

The documented source-build command reproduced both frozen totals exactly;
[its provenance](evidence/native-kv-lossless-2026-10-09/replay-provenance.json)
records all 41 verified archive members and 32 measured K/V packets. The
portable runner's 17 regression tests also pass, covering unsafe ZIP members,
hash/receipt mismatches, invalid codec receipts and verified compilation.

The production codec remains default off, excludes MiMo, and retains full
native allocation/admission bounds. Compression cannot reduce active native
attention buffers by itself. These samples do not qualify long prompts, varied
natural-language workloads, encrypted shared-page imports, disk endurance or
combined savings with the separate rotated INT4 implementation. Content-dependent
encoded lengths remain a distinct disk-observer privacy consideration; see
[the codec reference](../reference/ssd-kv-cache.md#dbk3-file-format).
