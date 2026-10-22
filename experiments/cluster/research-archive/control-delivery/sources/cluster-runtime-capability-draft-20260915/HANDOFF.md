# Runtime capability metadata draft

2026-09-15. Private proposal against main `605651bb9` plus its current reviewed runtime sources. No main, shared-build or native-build files were edited.

This adds a value-only installed-software descriptor, strict Protocol codec and a pure registered 9B producer. Configuration can select a supplied native Plan identity without copying Plan legality or fingerprint algorithms. The optional worker metadata branch verifies the installed executable file's SHA-256, reads exact registered configuration/manifest metadata, emits one descriptor and exits before the normal worker setup path.

`integration.json` maps all 13 Swift files: nine additions and four replacements. `runtime.patch` is the complete source delta. Preserve the four baseline hashes before applying; merge concurrent changes instead of replacing unrelated work.

## API and scope

`ClusterRuntimeCapabilityCodec.encode(_:)` and `decode(_:)` use exactly one canonical sorted-key JSON object plus LF, at most 16 KiB. Unknown fields and enums, missing fields, duplicate decoded keys, Boolean integers, fractional/exponent numbers, integer overflow, malformed hashes, inconsistent stage intervals and noncanonical bytes refuse. `capability.selection(planSHA256:)` selects an exact declared partition or throws.

The descriptor includes worker/owner/bootstrap versions, explicit runtime binary SHA, adapter/model/artifact/configuration/manifest identities, profile and its native fingerprint, whole-layer partitions with both stage/construction identities, and arithmetic policy/receipt SHA. It declares two ranks, B1, one active request, current 300-second/16-request ceilings, serial greedy text generation, selected-token stopping, request-owned KV/recurrent state, MTP off and no prefix reuse. It contains no membership epoch, hardware/device identity, availability, memory capacity or admission authority. No lookahead qualification is exposed.

The only producer is `QwenResidentCapabilityMetadata.describe(configuration:manifest:runtimeBinarySHA256:)`. It admits the exact registered Qwen3.5 9B metadata and uses the existing `QwenDenseRegisteredSpecification`, `QwenLayerStagePlan`, generation profile constructor and canonical arithmetic receipt. It emits cuts 4/8/12/16 and profile P8192/C512/O128/context8320. It neither reads tensors nor reconstructs an artifact hash from invented data. The artifact identity is the existing registered catalog value; configuration and manifest raw bytes must match that catalog.

The Protocol decoder checks a descriptor's closed schema and declared consistency. It does not independently prove that a Plan is legal, its hashes derive from the supplied configuration, or its profile is supported by a particular executable. Those values come from the native producer, and the configuration importer pins the exact descriptor bytes and selects an existing Plan. The pure producer's binary hash argument is caller-supplied. The command below supplies its separately checked installed-file hash.

## Worker metadata command

```sh
darkbloom-cluster-worker --describe-runtime \
  --config /absolute/model/config.json \
  --manifest /absolute/model/manifest.json \
  --expected-executable-sha256 LOWERCASE_INSTALLED_BINARY_SHA256
```

Order and fields are exact; default resident startup arguments and behavior are unchanged. Before configuration/manifest opens, the command resolves its own executable path and verifies that bounded regular file against the explicit expected hash. Executable reads stream in 64 KiB chunks with a 256 MiB ceiling; configuration/manifest ceilings remain 1/4 MiB. Reads use owned no-follow, nonblocking descriptors, require nonempty regular files and compare inode/device/mode/size/mtime/ctime with the descriptor and pathname afterward. Output is bounded and nonblocking. A fixed 15-second monotonic deadline and hard alarm cover this metadata-only invocation.

This verifies installed file bytes, not the mapped running image, linked libraries, source-to-binary reproducibility, remote installation or authenticity of a caller-provided file. The implementation calls no model/GPU APIs and does not open checkpoint payloads. The complete native executable has not yet been rebuilt or invoked with this branch; transitive native startup behavior remains for root's native check. A descriptor is never a readiness or physical/numerical/performance certificate.

## Preservation and validation

The existing Protocol object reader moved to its own internal file, with only a strict Boolean accessor added. Its old methods and the old codec body are byte-preserved. The existing SHA-256 body moved unchanged out of mixed model construction so the metadata closure requires only Foundation/CryptoKit. Model construction is otherwise unchanged. Resident caps/cuts/profile moved to one adapter definition shared by metadata and live admission; all original identity, arithmetic, source, resource and lifecycle gates remain intact. Removing the new metadata branch restores the original default WorkerMain text exactly. `check_extractions.py` verifies these transformations.

Final CPU validation (`records/final-checks/execution.json`, SHA `37c93af2430dbe7259884e79902408b8e07199f1a11fd430de2cebd61c7eb0f4`) passed in 6.13 seconds total:

- Swift 6 warnings-as-errors: actual Protocol module and the 16-file Foundation/CryptoKit metadata closure.
- New fixture: 6 accepted / 67 rejected cases, including exact retained cut4/profile/arithmetic fingerprints and complete four-partition coverage.
- Unchanged original Protocol fixture: 7 groups.
- Five actual CPU fixture children: installed fixture executable hash match, wrong hash rejected before a missing metadata path is opened, symlink input refusal, extra-option refusal and altered registered metadata refusal. This is a CPU fixture executable, not the native model worker.
- All 32 source/retained-metadata input pins unchanged. All 13 proposed Swift files syntax-parse. Existing-file preservation checks pass.

The first fixture compile refused a deprecated C-string initializer under warnings-as-errors; its receipt remains in `records/checks-1`. The replacement performs explicit bounded UTF-8 decoding. Subsequent and final checks pass. No native/MLX build, model/GPU execution, SSH or network work occurred.

Re-run the bounded CPU checks into a fresh directory:

```sh
/usr/bin/python3 fixtures/run_checks.py /absolute/d-inference /absolute/new-check-output
```

`source-inputs.json` pins the real reused sources and retained metadata; no broad fixture/catalog copy is introduced. Full native compilation and installed-worker metadata invocation remain pending. Source review by another agent may bind the frozen manifest separately; pending review is not a blocker claimed by this draft.
