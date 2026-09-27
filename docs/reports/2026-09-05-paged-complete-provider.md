# Provider integration of complete paged SSD checkpoints

> Last updated: 2026-09-05 · commit `169b342e6`

The provider now binds segmented paged storage to shared process admission and
constructs complete SSD stores from loaded recurrent or historical-attention
capabilities. Bounded host I/O and native destinations keep separate owners
through read, write, adoption and retirement. This is an integration milestone;
the default backend and exact-model rollout remain gated.

## Implementation

The production factory binds the empty paged backend before EngineV2 is created.
Its bridge skips duplicate contiguous-style per-request charges. Native admission
owns full request promises and actual paged backing, while provider read/write
permits cover bounded host buffers. Contiguous slots retain their existing
reservation path. Benchmark entry points share the same process authority.

Qwen complete checkpoints support native contiguous and segmented paged
storage. GPT-OSS and Gemma select their loaded historical-attention capability,
including a VLM's effective text target, and require exact paged storage identity.
Compatibility includes native layer dtypes, page/segment geometry, buffer bounds
and historical attention owner/window fields. Missing identity fails cold.
Normal persistent Qwen MTP codecs and stateless Gemma assistants remain distinct;
unsupported assistant state does not gain fabricated cache capability.

Shared SSD reads authenticate the manifest before native import allocation.
Provider host scratch is charged once; native buffers and metadata are admitted
separately. Read aliases unwind before returning the host permit. Writes claim
host capacity before encoding, retain it across the write stack, and expose
write-host ownership diagnostics. Explicit close waits for the existing I/O
drain; native array aliases keep their own retirement obligations.

The benchmark harness now uses production prompt/tool normalization, a
request-owned date and normal offline assistant verification. It records partial
failures atomically, exact token IDs and identities, process/allocator ownership
and independent trial labels. Cache and backend comparisons are separate axes;
decode rate excludes all tokens from the first nonempty MTP delta. The standalone
executable's final build and model runs follow the capacity-policy gate.

## Validation

Combined evidence covers **456 functions and 458 cases**, without a skip or
failure in the accepted groups. Candidate4 directly reruns the full 97-test
factory group after correcting four ready-status expectations. The other
13 groups, 359 functions/361 cases, ran on candidate3; their production,
dependency and test bytes are unchanged. They are carried evidence, not new
candidate4 invocations. Candidate4's build took 101.35 seconds.

Coverage includes loaded complete-store gates, shared read/write host ownership,
actual native-buffer lifetime, process and load admission, reslicing, heartbeat
wire fields, checkpoint storage, assistant preparation and benchmark input
regressions. The four production-input SPI checks pass; the separately frozen
Python harness passes 35 tests. Shared SSD and actual allocator suites execute
in separate processes to avoid unrelated allocator interference.

Root independently verified all final 55 payloads, 51 owned files, 674 selected
provider inputs, 480 native inputs, 1,356 dependency inputs and 27 Jinja inputs.
It checked the compiler graph and exact candidate3→4 source delta, applied the
canonical 44-path patch to parent `169b342e6`, and verified all resulting owned
file hashes. Native engine `aafe2069bcdeadef9250530eb511c598649c0355` remains unchanged.

## Preserved failures

| Attempt | Outcome and correction |
|---|---|
| Provider1 | Production built; two test semaphore waits needed a checked-continuation worker because direct blocking waits are unavailable in Swift async contexts. |
| Provider2 | 13 groups passed. Six factory tests retained old FP16 and attention-only Gemma expectations. Fixtures now use actual FP32 parameters, a real complete Gemma store, the existing identity seam, an isolated root/key and an attention-factory tripwire. |
| Provider3 | All other groups passed. Two positive tests expected scan-pending after the factory had awaited its scan; four assertions now require ready. |
| Provider4 | Full factory group passes with that test-only correction. No serving code changed between candidates2–4. |

## Limits and next gate

The old production fixed-pool sizing rule can refuse exact Qwen B1 before
requests begin. Its separately reviewed segmented-grant replacement is not part
of this commit. Fixed benchmark grants do not prove production capacity; the
next harness mode must derive and report the real loaded slot grant.

Actual allocator tests prove observation boundaries and alias retirement;
their temporary cap is restored before evaluation and OS availability is
non-binding. They do not prove continuously bounded whole-model scratch.
Exact five-artifact normal-MTP serving, B1/B2/B4 performance, live co-residency,
HTTP tools/vision, cross-machine routing and persistent-key OS restart remain
required. No seconds saved, decode improvement, paged default or release
completion is claimed by these unit tests.

## Evidence

The [manifest](evidence/paged-complete-provider-2026-09-05/manifest.json) and
[archive](evidence/paged-complete-provider-2026-09-05/payloads.tar.gz) retain
248 payloads, including failed attempts1–3, accepted execution scopes,
source archives, compiler graphs and harness evidence.
Manifest SHA-256: `1ebf0f08065a5ff9e02fefb32a370092f8cdc9f4401c46641c3dad830a83180c`.
Archive SHA-256: `f16d7b9139aa7b8af072988e3659e6ca4afe8a373f16d86893dcfa4cafaf87f1`.
Accepted provider manifest: `e1570b908619b02a5aec1a4dfff3fd8a6a918785f5fdf5e27e64d743c5361ead`.

Related: [native checkpoints](2026-09-05-paged-complete-native.md),
[prefix-cache architecture](../architecture/prefix-cache.md),
[benchmark validation](../developer/test.md#prefix-cache-benchmark-validation).
