# Native candidate metadata export

> Last updated: 2026-09-14 · commit `e4df336bc`

This CPU tool exports the candidates returned by the actual
[QwenLayerStageCandidates](../../Sources/ClusterInference/QwenLayerStageCandidates.swift)
and [Plan](../../Sources/ClusterInference/QwenLayerStagePlan.swift). It does not
duplicate cut predicates or native fingerprint serialization. It uses Foundation,
CryptoKit and the existing narrow test support; it does not link MLX or modify
the inference executable.

From this directory on macOS with the Swift toolchain:

```sh
bash run.sh --config /path/to/config.json --config-sha256 CONFIG_SHA256 \
  --canonical-names /path/to/canonical-names.json --canonical-names-sha256 NAMES_SHA256
```

Inputs are captured through nonblocking, no-follow descriptors. Each must be a
nonempty regular file within its cap; device, inode, mode, size and both timestamp
pairs must remain equal around the bounded read. Hashes bind those captured
bytes, without a claim about future path contents.

The names file is a JSON array of **already canonical** parameter names. Raw
checkpoint names must come through the existing model sanitizer before they can
be represented as verified canonical names. This tool checks native mandatory
name coverage and ownership; it cannot establish that the caller ran a sanitizer
or that checkpoint descriptors, shapes, dtypes, triplets or payloads are valid.

All four argument pairs are required. Both raw SHA-256 pins must be lower-case
hexadecimal. Configuration is capped at 1 MiB; names JSON at 2 MiB and 8,192 unique
nonempty names of at most 512 UTF-8 bytes each. Duplicate JSON object keys,
non-finite/invalid numbers, excessive nesting and name control bytes are rejected.
The original configuration bytes reach native Plan unchanged, including supported
floating-point metadata. A separate sorted-name JSON hash identifies the decoded
name set; the raw names hash also preserves whitespace/order evidence.

The one sorted-key JSON record includes native Plan/stage fingerprints,
construction-configuration hashes, source layer ranges, exact parameter and
state ownership, active roots, inert responsibilities and explicit exclusions.
Output is capped at 32 MiB including its newline; an oversized encoding produces
no record. This publication cap is not a whole-process memory bound. The temporary
executable is removed on exit. `CLUSTER_INFERENCE_SOURCE_DIR` can select another
production source directory for source-pinned development checks.

The catalog is **metadata only**. All compute costs remain unknown. It asserts no
artifact identity, actual sanitizer/descriptor/payload verification, model
construction, measured allocation, runtime eligibility or performance. In
particular, enumerating a 64-layer metadata configuration does not widen the
registered 27B loader or request admission. Runtime modes retain their own checks.

An offline adapter should hash the exact catalog bytes and join native
configuration/Plan/stage/construction identities to an independently qualified
load receipt. Compare the exported parameter ownership against the receipt's
actual `sourceName`/`localName` mappings. Bind artifact, source layout, arithmetic,
request/chunk, target device and measurement boundaries separately. A matching
Plan alone does not identify checkpoint weights. Do not recreate native JSON
fingerprints or interpolate unmeasured stages from layer counts in Python.

Pure checks reuse the existing retained 9B/27B metadata and public tiny fixtures:

```sh
bash ../../Tests/LayerStageCandidateExport/run.sh
```

They cover complete ownership across the returned candidates, all three wrapper
forms, a final layer range whose end is not interval aligned, raw versus semantic
input identities, strict refusals and bounded publication. Compiler and test
execution are pending for this source proposal; no model or performance result
is implied by these fixtures.
