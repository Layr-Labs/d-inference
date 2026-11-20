# Completed short-parity parent binding

This is a source-only contract for the frozen private parent, not an execution receipt. The exact parent package is `registered-dense-short-parity-parent-draft/manifest.json`, SHA-256 `5b6ce0b93cb6e5e5259fd62b2333e1efd062fb6242617d9d8e8fabbe39ab075f`. `receipt-contract.json` supplies the complete 71-field fresh and 73-field reuse key sets, source-derived constants and nested shapes. `source-pins.json` binds the sources used here. No launcher, helper, test, compiler, native binary or model was executed/imported; no candidate output was read.

## Receipt and raw inputs

1. Read caller-pinned original parent JSON, both manifests, complete stdout/stderr and prompt/teacher bytes through bounded, stable regular-file snapshots. Reject duplicate JSON keys, nonfinite values and Boolean substitutes for integers. Historical paths are labels; do not open paths taken from a receipt. A portable packet must separately supply every source/bundle member it wants verified. The old producer has no explicit serialized bound for its parent/source manifest; the new reader must state its own bounds.
2. Require the exact completed key set for `bundleAcquisition`. Require `status="completed"`, `nativeExecutionAttempted=true`, `nativeExecutions=1`, positive integer `nativePID`, `nativeReaped=true`, integer `nativeExitCode=0`, `primaryFailure=null`, and empty `cleanupErrors`, `postRunErrors`, `ownedProcessGroupAfter`. Require the exact true/false scope fields in the JSON contract. A failed or partial parent stays failed even when its native bytes separately pass a numerical audit.
3. Require `registeredProfile` to be one of the two frozen `PROFILES` keys (`registered_qwen35_9b`, `registered_qwen38_27b`), and exact `expectedIdentity == PROFILES[registeredProfile]` from the frozen pure contract. This includes configuration/manifest/artifact pins, tensor count, layers, source bytes and the 8/20 GiB sampled-RSS screen. The profile name is intentionally preserved verbatim.
4. `privateSourceSHA256` has exactly six names. Each value must equal its independently known frozen pin, and each supplied archived private file must hash to that pin: `run_short_parity.py`, `short_parity_contract.py`, `stage_load_contract.py`, `tiny_support.py`, `prefill_compute_archive.py`, `owned_bundle_reference.py`. A self-consistent replacement private file plus replacement self-reported hash is insufficient.
5. Prompt and teacher are exact raw bytes, not re-encoded JSON. Each is nonempty and at most 4096 bytes, containing respectively 3 and 1 exact integer IDs in `0..<248320`. Join actual byte count/hash/IDs to `rawTokenInputs.{prompt,teacher}`, `expectedPromptSHA256`, `expectedTeacherSHA256`, both native top-level raw pins and the freshly invoked numerical oracle's token inputs. `tokenFilesArchivedWithoutReencoding` must be true. The parent rechecked original and archived files separately; byte-identical supplied archives do not independently prove the historical originals existed.
6. Require `stdout.jsonl` and `stderr.log` receipt records to have exactly `{sizeBytes,sha256,hashOmittedBecauseOversized}` and match supplied raw bytes, with omission false. Stdout has exactly two nonempty LF-terminated records, at most 32 MiB each including LF and 64 MiB total. Stderr is exactly empty and has the empty-byte SHA-256. Retain all bytes; no diagnostic stripping.

These rules follow `run_short_parity.py:139–175,253–268` and `short_parity_contract.py:60–103`. The parent final success condition is at `run_short_parity.py:264`; it does not turn a native numerical assertion into independent numerical proof.

## Command, environment and process relationship

The receipt has no `output` field. Derive the historical run root from the exact command executable `<run>/bundle/cluster-inference`, or cross-check a separately supplied parent CLI summary. Require the entire 17-element command to equal frozen `native_command(...)` with:

```text
<run>/bundle/cluster-inference
--mode qwen-dense-short-parity-check
--model-dir <receipt.modelDirectory>
--registered-dense-profile <receipt.registeredProfile>
--tokens-file <run>/prompt.json
--tokens-sha256 <receipt.expectedPromptSHA256>
--teacher-tokens-file <run>/teacher.json
--teacher-tokens-sha256 <receipt.expectedTeacherSHA256>
--timeout-seconds 120
```

The process uses cwd `<run>/bundle`, `/dev/null` stdin and a fresh session/process group. The exact recorded environment is `{DARKBLOOM_BF16_WEIGHTS:"1", DARKBLOOM_CBV2_ATTN_QUERY_BLOCK:"128", MLX_ENABLE_TF32:"1"}`. The parent removes inherited keys beginning `MLX_`, `DARKBLOOM_`, `JACCL_`, then installs these three entries. Other inherited variables are neither removed nor recorded: do not claim a closed complete process environment. `runtime` is the historical repository's `experiments/cluster/runtime`; `release` and `modelDirectory` are resolved paths. They are not fresh-file lookup instructions for the CPU adapter. See `run_short_parity.py:123–138,204–219` and `tiny_support.py:25`.

Supply the runtime DTO validator the same positive `nativePID` and the exact historical launch bundle root. For reuse, it may additionally receive the recorded `bundleReference.resolvedPath`; do not automatically add `requestedPath`, which is input spelling, not the launch/cwd. Do not follow live symlinks to validate old runtime strings. Optional native runtime fields remain subject to the separately pinned native DTO validator.

The receipt records native exit/reaping, not its own parent process exit code. If the orchestration claims the launcher itself exited zero, it needs a separately pinned invocation result; a completed JSON file alone does not establish that final process outcome. The CLI summary fields are `{status,receipt,sha256,primaryFailure,cleanupErrors,postRunErrors}` and can bind its reported receipt bytes, but are also unsigned records.

## Source archive relationships

`source-manifest.json` raw SHA-256 must equal `sourceManifestSHA256`; its exact shape is `{schema_version,repository,files,dependencies}`, version integer 1. `sourceFileCount` equals the number of unique entries. Each entry is `{path,size_bytes,sha256}` with a normalized relative POSIX path, nonnegative exact integer size and lowercase SHA-256. Require exact coverage by the packet's source-file mapping and independently rehash every supplied member. `manifest.repository + "/experiments/cluster/runtime"` must agree with `receipt.runtime` as a historical string.

The source archiver selects inference `Sources/**/*.swift`, runtime `**/*.py` and `**/*.md`, inference `Package.swift`, `Package.resolved`, `build.sh`, `prepare_dependencies.py`, and repository `.gitmodules`, `libs/mlx-swift/Package.swift`, `libs/mlx-swift-lm/Package.swift`. It does not archive all dependency implementation sources, tests or model files. Its dependency object is exactly `{repository_head,submodules,tracked_dependency_changes}`; the last string must be empty. The recorded head/submodule strings are context, not proof of a clean entire tree or compiler input set. Untracked dependency changes are excluded from the producer's dirty check. See `prefill_compute_archive.py:31–79`.

The parent loads runtime `bundle`, `artifacts`, `configuration`, `processes` from the archive and compares archived/live selected files and dependency strings before/after. The new adapter must pin supported runtime helper and native DTO source bytes independently, not accept arbitrary replacement implementations because they appear in a coherent manifest. Native source/Metal/executable relationship remains a separate build-provenance assertion: the source manifest itself contains no build-to-binary proof. A recorded executable SHA only identifies bytes.

## Bundle branches

In both branches, raw `bundle.json` SHA equals `bundleManifestSHA256`. Parse exact `{schema_version,files}` with integer version 1; entries have `{path,size_bytes,sha256}`, unique normalized relative names and no manifest self-entry. Require the packet's bundle-file mapping to cover exactly those members and rehash each. `cluster-inference` must equal `expectedNativeSHA256`; `rank_worker.py` and `artifacts.py` must equal the corresponding archived runtime members. The CPU adapter verifies supplied bytes, not historical ownership, inode permissions or the code actually mapped into the process.

| Branch | Exact receipt distinctions | Producer behavior and limit |
|---|---|---|
| `fresh_snapshot` | `bundleCopiedForThisRun=true`; no `bundleReference` or helper-hash field | Copies release `cluster-inference`, `mlx.metallib`, `mlx-swift-lm_MLXLMCommon.bundle`, and the archived worker/artifacts source; writes bundle manifest. Normal files become 0400, executable 0500. Postflight verifies listed member sizes/hashes and manifest hash; it does not apply the reuse helper's exact-tree, ownership or no-extra-file checks. |
| `reused_external_reference` | `bundleCopiedForThisRun=false`; exact 9-key `bundleReference`; `bundleReferenceHelperSHA256=c4832e457307f683f5aff55cafefe6feeeaf6a69ad1be2dc220325f96f5da8a4` | Creates only `<run>/bundle` symlink to the validated resolved root; repeats reference checks before launch and independently after the general archive check. It makes no fresh-copy claim. |

Reuse reference shape is `{kind,schemaVersion,requestedPath,resolvedPath,copied,manifestSHA256,expectedNativeSHA256,verifiedFileCount,runtimeFilesSHA256}`. Require kind `owned_read_only_bundle_reference`, version integer 1, copied false, manifest/native pins equal the parent, file count equal manifest count (1–128), and runtime hash map exactly `{rank_worker.py,artifacts.py}` joined to both manifests. Paths are absolute historical strings; `resolvedPath` is the permitted extra runtime alias.

At execution the reuse helper rejected symlinks inside the source tree, required each entry owned by effective UID, regular files with no write bits, directories with no group/other write bits, exact file/directory coverage, owner-executable native, and stable requested/resolved/link relationships. No UID/mode/inode evidence is encoded in bundle entries, so these remain producer assertions during portable replay. The owner can change its own permissions; neither branch is an attestation mechanism. See `owned_bundle_reference.py:27–106`, public `runtime/bundle.py:10–33` and `runtime/artifacts.py:30–56`.

## Observations and final numerical join

Completed source control flow yields equally sized `memorySamples` and `powerObservations`, at least three entries (initial, prelaunch, released). A fast process may yield no live sample: missing RSS stays unknown. Basic sample shape, optional owned PID/PGID/command fields, and terminal-race fields are in the JSON contract. Preserve raw `vm_stat`, `sysctl` and power text if supplying the full parent. Do not label parsing those statements as independent historical OS observation.

Policy constants remain native 120 seconds, parent 135 seconds, actual free at least 6 GiB, pressure 0…2, absolute reported swap zero, AC or battery at least 15%, and profile RSS screens 8/20 GiB. A `"<defunct>"` sample was accepted only for integer zero RSS, owned PID=PGID, and a terminal result from that `Popen`; on a completed run that result is zero. The postflight sample has no native PID. Parent start/end wall timestamps include setup/postflight and the monotonic deadline origin is not saved, so they do not independently prove the 135-second execution deadline. Do not require positive/live RSS or infer a measured whole-process peak.

Root can reuse the frozen pure `validate_result(raw,profile,tokens)` and compare all its returned fields to the parent; do not import `run_short_parity.py`. Then run the pinned numerical oracle freshly on the same snapshotted stdout and exact token bytes. Require its complete passed result and join `profile`, `stdoutSHA256`, `stdoutBytes`, `recordedRequestFingerprint`, `referenceAdmissionFingerprint`, `baselineEvidenceSHA256` to the parent/raw bytes. The frozen numerical result does not return a Plan/profile fingerprint: those stay joined through the raw native DTO and outer result; do not invent such result fields. Retain the numerical oracle's own false limits (raw state values, loaded-stage inventory, resource/lifetime/Plan serialization, model payloads, provider/performance qualification).

A binding result can truthfully say supplied raw files and their cross-record metadata were checked, numerical replay was performed, and runtime DTO consistency was checked. It cannot conclude from these unsigned records that the historical process ran this binary, the binary was built from the archive, a particular metallib was loaded, hardware/NAX eligibility was qualified, live resource screens were independently observed, or another device produced the result.

## Useful refusal cases

- Failed/incomplete receipt, extra completed-schema fields, Boolean counters, cleanup/postflight error, missing stream pin, nonempty stderr or an incomplete first-only stdout.
- Correct token IDs but wrong raw bytes/hash, wrong profile/command order/archived token path, changed private source with a coherently replaced self-reported pin.
- Changed/missing/extra supplied manifest member; cross-manifest worker/artifacts mismatch; wrong native pin; reuse fields on fresh or missing on reuse; wrong reuse count/runtime hash/link-root claim.
- Fresh numerical replay supplied different stdout/tokens, or any returned identity/evidence hash differing from the parent.
- Runtime DTO PID differs, full/pair runtime records disagree, or runtime paths use an unapproved alias. Missing optional runtime fields must follow the pinned native DTO contract, not an invented required field.

These are prospective CPU cases, not author-executed tests or new native evidence.
