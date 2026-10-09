# Lossless complete-checkpoint codec measurements

> Last updated: 2026-10-09

The optional production byte-plane/LZ4 codec restores native bytes exactly and
reduces the selected public Qwen BF16 packet by 26.76% across K and V. This is
a CPU codec measurement, not a model-quality, disk-throughput, restore-latency
or active-KV-memory qualification.

## Method

Compile the actual production
`provider-swift/Sources/ProviderCore/KVCacheSSD/SSDLosslessChunkCodec.swift`
with `swiftc -O` alongside [the standalone driver](evidence/lossless-checkpoint-codec-2026-10-09/main.swift).
The driver defines only the codec error contract; it does not copy the codec.
It slices inputs into the production four-MiB segments and performs five
encode/decode repetitions, asserting every restored byte equals its source.

The source is one BF16 full-attention owner from the controlled public
Qwen 3.6 35B benchmark captured on 2026-09-06, using a repeated water
infrastructure paragraph. It is not private consumer KV and does not
establish compressibility for varied prompts, Gemma, GPT-OSS or packed INT4.
Native K and V each contain 5,719,040 bytes. Their SHA-256 values appear in
the raw result files below. The original source archive is
[`qwen36-owner0-packets-2026-09-06`](evidence/qwen36-owner0-packets-2026-09-06/manifest.json).

## Results

| Tensor | Native bytes | Framed encoded bytes | Reduction |
|---|---:|---:|---:|
| K | 5,719,040 | 4,288,693 | 25.01% |
| V | 5,719,040 | 4,088,778 | 28.51% |
| Combined | 11,438,080 | 8,377,471 | 26.76% |

All five repetitions are bit-exact. Encoding takes roughly eight milliseconds
and decoding roughly four to five milliseconds per tensor on the local M4 Max.
These timings exclude AES, filesystem I/O, device readback and model execution.
See [K samples](evidence/lossless-checkpoint-codec-2026-10-09/keys-refactored.json),
[V samples](evidence/lossless-checkpoint-codec-2026-10-09/values-refactored.json)
and [source/binary digests](evidence/lossless-checkpoint-codec-2026-10-09/sha256.txt).

The independent refactor reduced encoder buffers from four native-sized buffers
to three. One fresh-process before/after measurement reduced maximum RSS from
52,543,488 to 44,040,192 bytes. This includes the driver's retained corpus and
results; it is not a proof of the provider's I/O reservation or Mac-wide peak.
Raw observations: [before](evidence/lossless-checkpoint-codec-2026-10-09/before-memory.txt),
[after](evidence/lossless-checkpoint-codec-2026-10-09/after-memory.txt).

## Serving and validation boundaries

The provider implementation is an explicit default-off experiment, with MiMo
excluded. New readers restore legacy raw files; compressed files authenticate
their codec and native decode size. Encoded write admission charges header,
framing, ciphertext and tags before physical writes, including writes whose
atomic temporary file is later discarded. Native RAM admission is unchanged.

The refactored provider builds and 65 focused tests across codec, streaming,
complete-state restoration, write endurance/priority and daemon-environment
serialization pass. This result does not replace full component/CI, privacy
review or full-model data qualification. Compressed lengths depend on KV
content and remain visible to a disk observer; prior timing-risk approvals do
not cover that signal. See [the codec reference](../reference/ssd-kv-cache.md#dbk3-file-format)
and [privacy model](../architecture/security/encryption.md#provider-cache-storage).
