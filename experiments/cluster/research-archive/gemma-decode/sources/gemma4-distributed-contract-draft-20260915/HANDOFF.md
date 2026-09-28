# Handoff

Ready for source review. This is a private metadata implementation and concrete native patch contract; MAIN and prior artifacts are unchanged. No compiler, model constructor, payload read/full-weight hash, remote operation or bulk transfer was performed.

Start with [CONTRACT.md](CONTRACT.md) for artifact, stage, native-gate and state semantics, then [IMPLEMENTATION.md](IMPLEMENTATION.md) for the exact reusable interfaces and source edits. [FIXTURES.md](FIXTURES.md) separates the 11 executed pure checks from future Swift/native/physical work.

Implemented files are `artifact.py` (strict retained metadata join), `geometry.py` (exact tensor shape/quantization/state derivation), `partition.py` (unique sources and explicit replicated destinations), and `derive.py` (bounded producer). `test_contract.py` uses the actual retained header/index/config data plus malformed metadata mutations. The modules do not import MLX or open payload files.

The header-derived text source has 1,339 tensors / 14,467,688,508 bytes. Both ranks need one 415,236,096-byte tied embedding triplet, so destination coverage is 1,342 tensors / 14,882,924,604 bytes. Cut 15 has 672/670 destination tensors and 7,437,403,934 / 7,445,520,670 bytes. Cut 12 and all 29 possible splits are also derived; cut choice is unqualified.

The most important implementation traps are original 30-layer kernel geometry, final narrowing only at global layer 29, full-row rank 0 residual ingress/egress, K/V independence despite `attention_k_eq_v`, fixed 1,024-slot sliding rings, empty recurrent state snapshots, exact 8-bit shared/router versus 4-bit experts, and unique-source versus replicated-destination conservation. The existing custom GeGLU constructor performs a tiny native activation probe; do not label model construction as metadata-only.

`checks.json` records the direct execution receipts: derivation passed, 11 unittest methods passed in 0.162 seconds reported by unittest. `source-pins.json` binds 30 examined source files; `derived/input-pins.json` binds seven retained metadata/header inputs. `manifest.json` binds this new package, excluding Python bytecode and the manifest itself. No independent review is claimed: arithmetic's supplemental read remains pending because root-critical work occupied its slot.

Reproduce only the pure metadata work from this directory:

```sh
python3 -B -m unittest -v test_contract
python3 -B derive.py --output /private/tmp/gemma4-contract-replay-UNIQUE
```

The output directory must be new. The tool accepts no payload path or remote target. Existing `derived/` is frozen and must not be overwritten. The expected output preserves `wholePayloadHashesVerified=false`, `nativeExecutionQualified=false` and `nativeKVDTypeVerified=false`. Physical guards, actual payload authentication, native resource accounting and future product admission remain mandatory follow-up work, not achievements of this mapper.
