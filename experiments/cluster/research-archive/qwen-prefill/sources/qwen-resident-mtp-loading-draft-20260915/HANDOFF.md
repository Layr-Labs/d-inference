# Qwen 9B inline MTP storage preparation

This private overlay prepares the inline assistant's weights on rank 1. It does
not enable MTP generation, change the worker protocol, advertise a capability,
or alter the ordinary MTP-off load path. MAIN and all physical run inputs remain
unchanged by this task.

The internal entry is
`loadQwenResidentStageWithMTPAssets(_:check:) -> QwenResidentStageWithMTPAssets`.
It accepts the existing typed resident admission, rejects every rank except 1,
verifies the same registered artifact, and keeps its verified descriptors alive
through target and assistant loading. The returned native-only value owns the
target, assistant and additive CPU load receipt. A future resident owner must
retain and retire both native values under its existing process lease; this is
not a second process supervisor or an independently callable serving engine.

The 927-tensor target Plan, inventories and conservation receipt stay unchanged.
The MTP head remains outside that Plan. Rank 1's residual-ingress placeholder is
not replaced: the assistant owns a separate input embedding and calls the
already-loaded target final norm and output head. The assistant still binds the
target's native object identity. Its existing committed-history, final-norm,
speculative-cache trim and release methods are unchanged.

| Additional storage | Tensors | Source bytes |
| --- | ---: | ---: |
| Inline `mtp.*` head | 31 | 136,881,152 |
| Explicit input-embedding replica | 3 | 572,129,280 |
| Total | 34 | 709,010,432 |

These are source payload bytes, not a whole-process memory prediction. The
typed additional-load ledger adds actual allocator bounds for all 34 tensors
to the pending target-stage reserve, and includes the maximum staging tensor
and the existing aligned-read scratch allowance. The ordinary loader receives
nil and retains its original arithmetic. During assistant loading, the current
tensor remains reserved until its evaluated, synchronized, uniquely owned
allocation passes shape/dtype/byte/buffer checks. Actual free-memory, swap,
pressure, power, thermal and allocator checks remain required. No floor changes.

The new MLXLLM SPI, `Qwen35InlineMTPAssistant.loadVerifiedInline`, factors the
existing constructor and quantization code from the local inline loader. Its
mandatory callbacks receive complete parameter names and expected geometry;
the runtime supplies evaluated tensors from the verified selected reader.
It performs no file IO, whole-shard loading or request-state creation. Any read,
callback, allocation or validation failure prevents publication. Recorded native
faults retain precedence over a secondary Swift error.

Files are listed and hashed in `integration.json`; `runtime.patch` applies only
the two existing-file changes and seven additions. The existing-file bases are
preserved under `originals/` and pinned in `base-pins.json`. The selected reader,
resource floors, target model/session/driver and current prefill selection are
not modified. The prefill overlay can be integrated independently.

Validation completed:

- A 13-source, Swift 6 warnings-as-errors Foundation fixture passed on its first
  compile/run: **9 accepted / 31 rejected**, with empty stderr. It uses the real
  Plan, placement, allocator-bound ledger and ordered progress sources. Cases
  cover all current cuts, unchanged embedding/head ownership, missing/extra/
  duplicate/wrong-dtype/wrong-shape descriptors, byte mismatch, wrong rank,
  allocator underestimation/overflow, ordered advancement and failure poisoning.
- All nine proposed Swift files passed syntax parsing. This does not typecheck
  the MLX callback/factory/materializer path.
- `Tests/check_preservation.py` reverses only the named extraction/ownership
  seams and obtains both original files byte-for-byte. It also verifies exact
  quantization-body extraction, unchanged history bodies, and the 34-tensor
  metadata totals. This is a source check, not numerical execution evidence.

The config fixture is the exact existing repository fixture. The small tensor
fixture was extracted from the retained `weight-layout.json`, whose hash and
origin are in `Tests/fixture-provenance.json`. That layout is not an artifact
manifest member and cannot authorize a payload read. The actual loader still
requires the verified manifest, full checksum verification, headers and index.
No model payload was read, and no MLX/model/GPU execution occurred in this task.

Replay the completed pure checks with a new receipt directory:

```sh
python3 Tests/run.py cpu-replay
python3 Tests/check_preservation.py preservation-replay.json
```

Before integration, the parent must apply the overlay to an isolated matched
library dependency tree and typecheck `DarkbloomClusterRuntime` with jobs 2.
The MLXLLM changes must be present in that isolated dependency, not in mutable
MAIN. Actual selected-load ownership and numerical execution remain untested.
The current pure fixture does not claim successful native assistant loading.

Subsequent MTP work must bind placement/mode in bilateral pre-load admission,
charge assistant request history and verification workspaces, and route the
final rank's **committed pre-final-norm target hidden states** into the existing
assistant history API. The current stage session does not expose that history.
Accepted-prefix commit/rollback, authoritative target verification on both
ranks, clean cancellation and retirement need implementation before any MTP-on
profile or generation flag is offered. Stage-0 residuals are not a substitute
for final-trunk hidden history.

Independent source review is pending separately at this handoff; preserve this
history if a later review or native typecheck adds a correction.
