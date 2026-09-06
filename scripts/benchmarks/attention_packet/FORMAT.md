# Offline attention packet v1

One directory contains `packet.json`, a raw JSON-encoded `CBv2AttentionMetadataSnapshot` in `attention-metadata.json`, and six raw tensor files. The snapshot is the value normally inside `attention_metadata.snapshot`, without either wrapper. This interface is diagnostic only. It does not certify native operator replay, full-history storage correctness, model-token equality, or any numerical release gate.

The packet binds the snapshot by its exact byte length and SHA256. Here `identity.artifactSHA256` is the actual verified loaded target model aggregate hash (`Loaded.verifiedModelHash`), and `inputSHA256` hashes the benchmark’s actual input bytes. The wrapper/run evidence separately binds the probe executable. It identifies the loaded model and input by these recorded IDs/hashes; this offline tool does not reopen weights or requests to authenticate those declarations. `recordIndex` must be zero and selects the only observed owner: v1 requires `expectedOwnerCount=1` and exactly one metadata record. Multi-owner or duplicate-owner snapshots are explicitly unsupported/inconclusive, even if they declare a matching count. Retain the existing snapshot fields `configuration`, `selectedForwards`, `expectedOwnerCount`, `forwardSucceeded`, `sampleOutcome`, `seedToken`, `targetToken`, `refusals`, and `records`. Each record retains its exact current schema, including `requestID`, `outputIndex`, `phase` (`decode` or `chained_decode`), `batchIndex`, `batchSize`, `inputWidth`, `storageLayerIndex`, `modelLayerIndex`, `offsetBefore`, `offsetAfter`, `scaleBits`, `dispatch`, `kernelOutputDType`, `queries`, `incomingKeys`, `incomingValues`, `output`, `storage`, and presence flags. Graph-construction strides are observational metadata; they never describe packed payload layout.

Example below uses placeholders for SHA256 and metadata size. It describes QH=4/KVH=2/D=4/T=3, original FP32 Q and output, BF16 stored and incoming K/V. A producer must replace every placeholder with actual values. No implicit dtype, shape, endian, stride, tensor, or file is accepted.

```json
{
  "schema": "darkbloom.attention-packet.v1",
  "identity": {
    "modelID": "actual-model-id",
    "artifactSHA256": "<64 lowercase hex characters>",
    "inputSHA256": "<64 lowercase hex characters>",
    "backend": "paged"
  },
  "metadata": {
    "file": "attention-metadata.json",
    "byteCount": 1234,
    "sha256": "<64 lowercase hex characters>",
    "recordIndex": 0
  },
  "geometry": {
    "attention": "full",
    "isBidirectional": false,
    "sharesKV": false,
    "mtpEnabled": false,
    "visibleStart": 0,
    "visibleEnd": 3
  },
  "capture": {
    "evaluationStatus": "completed",
    "tensorPayloadBytes": 256
  },
  "tensors": {
    "queries": {
      "file": "queries.bin", "dtype": "float32", "byteOrder": "little",
      "shape": [1,4,1,4], "packedStrides": [16,4,4,1],
      "byteCount": 64, "sha256": "<64 lowercase hex characters>"
    },
    "storedKeys": {
      "file": "stored-keys.bin", "dtype": "bfloat16", "byteOrder": "little",
      "shape": [1,2,3,4], "packedStrides": [24,12,4,1],
      "byteCount": 48, "sha256": "<64 lowercase hex characters>"
    },
    "storedValues": {
      "file": "stored-values.bin", "dtype": "bfloat16", "byteOrder": "little",
      "shape": [1,2,3,4], "packedStrides": [24,12,4,1],
      "byteCount": 48, "sha256": "<64 lowercase hex characters>"
    },
    "incomingKeys": {
      "file": "incoming-keys.bin", "dtype": "bfloat16", "byteOrder": "little",
      "shape": [1,2,1,4], "packedStrides": [8,4,4,1],
      "byteCount": 16, "sha256": "<64 lowercase hex characters>"
    },
    "incomingValues": {
      "file": "incoming-values.bin", "dtype": "bfloat16", "byteOrder": "little",
      "shape": [1,2,1,4], "packedStrides": [8,4,4,1],
      "byteCount": 16, "sha256": "<64 lowercase hex characters>"
    },
    "output": {
      "file": "output.bin", "dtype": "float32", "byteOrder": "little",
      "shape": [1,4,1,4], "packedStrides": [16,4,4,1],
      "byteCount": 64, "sha256": "<64 lowercase hex characters>"
    }
  }
}
```

All payloads are tightly packed row-major `[batch, head, chronological_token, channel]`. Strides are element counts. Supported dtypes are `float16`, `bfloat16`, and `float32`; byte order is explicitly little-endian. Native raw bytes are preserved; all finite FP16/BF16/FP32 values promote losslessly to FP32 for numerical analysis. Bit promotion also preserves signed zeros and signaling/quiet NaN payloads; nonfinite inputs are counted and never admitted to the primary arithmetic reference. Native bit patterns remain available for bitwise checks, including NaN payloads. The original Q is captured before backend narrowing; output is the original return before gate/output projection. Stored K/V are post-update logical native storage values, not physical page bytes. Incoming K/V are the selected original call's one-token rows. v1 requires incoming and stored K/V dtypes to match; conversions require a future explicit schema, not an implicit cast.

Every path is relative to the packet directory and must remain inside it after symlink resolution; traversal, absolute paths, duplicate files, non-regular files, incorrect lengths/hashes, unsupported dtypes, and non-packed strides refuse. Each JSON file is at most 256 KiB, total tensor payload is at most 32 MiB, and tensor shapes are checked against exact byte counts before allocation. The selected geometry requires B1, L1, full causal text attention with visible absolute range `[0, offsetAfter)`, `offsetAfter = offsetBefore + 1`, and no shared KV, bidirectional attention, MTP, sinks, softcap, or spans. QH must be a positive multiple of KVH. `scaleBits` must encode a finite positive FP32 value. CPU analysis is also bounded to at most 256 query heads, head dimension 1024, and 100 million multiply-add terms per reference; supported QH16/KVH2/D256/T5585 fits this bound. GQA uses `kvHead = queryHead // (QH / KVH)`.

Only `forwardSucceeded=true`, `sampleOutcome="confirmed"`, one selected forward, matching selected request/output identity, exactly one complete owner record with no refusals, and `capture.evaluationStatus="completed"` permit the primary numerical reference. Discarded, failed, unconfirmed, or unsupported selection is inconclusive and cannot interpret the selected request decision. This reconciliation does not itself prove that capture fence/lifetime code was correct.

The analyzer reports each tensor's nonfinite counts, bitwise last-row stored/incoming consistency, and per-head/global L-infinity, RMSE, and relative-L2 for the original-Q FP32 softmax reference. The latter is an independent FP32 calculation, not exact real arithmetic. Reference rounding to outward output dtype is a separate comparison. Only original FP32 Q with FP16/BF16 storage gets a separately labeled narrowed-Q counterfactual; it never replaces the primary reference. Nonfinite comparisons and zero-reference relative-L2 are reported explicitly, never made finite by dropping elements or adding an undocumented epsilon. There is no numerical or model-token pass flag.

The last-row check can detect a mismatched selected write, but identical gather/decode layout faults or earlier missing history still require an independently captured incoming-KV mirror. Cross-backend tensor identity and actual same-input native operator replay are separate work.
