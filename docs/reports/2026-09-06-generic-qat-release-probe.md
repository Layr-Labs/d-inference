# Optimized probe for the Gemma QAT diagnostic retry

> Last updated: 2026-09-06 · commit `17dbfa8aa`

The optimized `radix-engine` probe builds from the committed generic-diagnostic,
persistent-namespace, packet-capture and cancellation-settlement source union.
All 25 parser checks pass. This record ends at the QAT controller handoff; it
contains no model result, speed claim or release activation.

## Exact source and artifact

The parent is `6790dea1c7044ca336cd6383aac7e6d27afb7359`, with native gitlink
`b01e1af06902c82e22227bf923447cc71c47b148`. Compared with the previous packet and
cancellation probe, eight provider and six benchmark file changes match the
banked namespace source, and nine native changes match the
[generic reducer validation](2026-09-06-generic-logit-diagnostic-reducer.md).
The independent operator-replay source is outside this snapshot.

The release build succeeds in 253.37 seconds. The executable is 80,663,888 bytes,
regular mode `0755`, with SHA-256
`3de3086d924e38893c31583f47309f3345733364956e0972287fa1ef7a6966c7`.
All six runtime resources match build8 bytes, sizes and modes. No provider CLI
is rebuilt. The existing local MLX dependency overlay and resolution pins remain
unchanged.

Source manifests retain 688 provider, 909 canonical native and 20 canonical
benchmark inputs. Compiled package metadata adds one native and one benchmark
resolution file. The root review checks 1,027 declared compiler references:
420 provider, 317 native, 20 benchmark, 256 dependency and 14 Jinja references.
The graph uses pinned local MLX sources and the immutable snapshot. Graph
membership alone does not assert that every declared target links into the
selected executable.

## Validation and handoff

Ten valid parser combinations cover both backends, normal-MTP logit capture,
combined diagnostics and namespaced persistent options. They reach the owned
empty-input guard. Fifteen invalid or mixed combinations refuse earlier.
Namespace validation only inspects paths; no model/config/key/cache operation
occurs, and the model, cache and packet output paths remain absent.

The earlier generic native tests retain their actual 96-function/105-case scope.
Namespace evidence retains its separate provider23 and final benchmark24 runs;
these are not relabeled as a new combined-union model test.

The QAT successor keeps the original input, assistant, four ordered cells,
normal MTP, cache-off ephemeral mode, five runner files and strict confirmed-MTP
checks. Only owned roots and the reviewed probe binding change. Three CPU tests
render all eight remote snippets without execution, verify those exact deltas,
and refuse a wrong binding before host work. The c153 capability failure remains
separate evidence; the subsequent model retry is recorded separately.

## Evidence

The [manifest](evidence/generic-qat-release-probe-2026-09-06/manifest.json) and
[archive](evidence/generic-qat-release-probe-2026-09-06/payloads.tar.gz) retain
99 payloads (2,210,919 bytes): source/build proofs, raw parser results, root
reviews and the controller handoff. The executable and six runtime resources
are excluded; their exact identities remain in the artifact proofs.
Manifest SHA-256: `8d9fa4fa89eefde9e6e9243faf6238a8abd324cfbdf94f7509e5f11d34547f23`.
Archive SHA-256: `df0a58881997c7f8f3fdc7a4d4b3eb28721ee0cd39926a87504bf3e53c2a426c`.
