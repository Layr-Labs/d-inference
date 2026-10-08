This is a Foundation-only draft for the `prompt_lookahead_one_v1` wire flow. It does not change repository Sources or the tested bare v1 APIs. The envelope contains exactly `{"version":2,"flow":"prompt_lookahead_one_v1","boundary":<v1 header>}` and is bounded to 16 KiB in total.

`QwenLayerStageLookaheadWireEnvelope.init(boundary:expected:)` validates actual producer metadata against a locally admitted v1 expectation, then creates canonical outer bytes. `decode(_:expected:)` scans the complete original JSON with `validateWorkerJSON` before Foundation parsing. That scanner rejects duplicate decoded keys at every depth and any fractional or exponent-form number lexeme. Original outer and nested integer values also pass `BoundedProbeInput.integer` before nested serialization. The unchanged v1 decoder validates the complete inner schema and local identity.

The value is not `Decodable`, so there is no alternate Codable receive entry. Its `boundary` property exposes the validated v1 header. Its `encoded()` method returns the exact admitted outer bytes, including accepted whitespace and the valid integer spelling `-0`. Re-encoding the inner object does not replace those bytes. Changing only those spellings therefore changes the ACK identity.

`QwenLayerStageLookaheadWireAcknowledgement` provides `Phase.ready`, `.received`, and `.consumed`, `values(envelope:phase:)`, and `validate(_:envelope:phase:)`. Its 64 Int32 elements are the UTF-8 hexadecimal characters of:

```
sha256("qwen-stage-ack-v2|prompt_lookahead_one_v1|<phase>|<sha256(exact outer bytes)>")
```

The wire representation of those elements is 256 little-endian bytes. `received` and `consumed` are distinct identities; the codec does not implement or establish either transition. Local admission, ownership, sequencing, transport completion, and failure retirement remain the caller's responsibilities.

`QwenLayerStageLookaheadWireCheck.swift` exposes `checkQwenLayerStageLookaheadWire(includeVectors: false)`. The default emits a compact summary plus rejection labels; the standalone harness requests vectors. `prepare_foundation_harness.py` concatenates the exact eight existing Foundation dependencies, the three draft Swift files, and small Foundation/CryptoKit support functions. It does not execute the harness or build the inference target.

The authorized `/usr/bin/swift foundation-attempt-1/harness.swift` check completed with exit 0 and empty stderr. Existing v1 checks accepted 6 and rejected 44 cases. New v2 checks accepted 21 and rejected 70 cases, including both incompatible v1/v2 directions, raw nested duplicate aliases, fractional/exponent/boolean numbers, closed schemas, local token/frame mismatch, phase/hash replay, whitespace, negative zero, and the exact 16 KiB limit. Python independently regenerated all 21 envelopes and 63 ACK vectors; its 12 regression tests passed.

`validation-20260914.json` binds source inputs, the interpreter harness and outputs, Python oracle/tests, and vector hashes. This establishes CPU codec behavior only. There was no MLX import, inference target build, model read, GPU work, socket operation, or payload transport.
