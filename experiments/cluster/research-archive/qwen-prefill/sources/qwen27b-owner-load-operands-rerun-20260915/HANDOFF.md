# Private 27B load-operand diagnostic rerun

Ready for root review and copy-only deployment. No remote commands, model loads, or native runs were performed by the preparer. The earlier failed runs and every prior tree/bundle remain unchanged. This package measures the exact load-refusal operands; it does not change admission policy or establish numerical correctness.

## Exact binding

- New remote root on both Macs: `/Users/developer/DarkbloomDev/qwen27b-owner-load-operands-20260915`.
- Fresh membership epoch: `9b85e05e-9257-448d-8e29-69654dd1c358`. Existing cluster ID retained; request UUID `20801ced-ca29-4faf-b71a-9ebbe1886a14`, P32/C16/O128, cut32, serial, empty stops and MTP-off retained.
- Native: `989f701ca6a8178ebc41b73e840a937c17aa9b0a3f8a53b9fee8432a4cd5ffdb`. Actual isolated build PASS in 221.926333875 s, exit0/reaped/group absent. Build receipt `2e773309f22b5465099289c0b59d9d549c00757618cfc0fd484b73b891049be8`; three-file native bundle `44ca36d0366501b78fe1e150bd9b5849988335cb0980bfc8cc9989d4b56b2536`.
- Exactly one of 3,040 source files differs from the a7c35 baseline: reviewed `QwenResidentLoading.swift` adds diagnostic operands and phase/read-admission labels. All 8,755 dependencies remained pinned during the build. No formula, guard, allocation, materializer, or storage/arithmetic declaration changed.
- Diagnostic owner `da5542b115279db5f3f6e0794d96cdaa54cff1d193bee8c9d4bb24edc870c8a8`, its coherent four dylibs, and local draining controller `862f7a391afd8f490233db793034c1ec8648c52fd908ba39abbefbf46e899d78` plus its four dylibs are unchanged. The local and remote Remote dylibs deliberately differ; the local endpoint contains the tested stderr-drain correction.
- Both peer build IDs in all three Ready templates and metadata now name the actual new native. Templates retain zero-epoch/capacity1 placeholders; actual Ready remains authoritative. Outer configs and embedded records are compact JSON plus exactly one LF.
- Existing corrected `prepare_expected.py` actually ran locally. Expected agreement SHA `e24e71636d32a7f27bddc3f31df652e0034e0ce5d84639d795bd2be66970b621`; only membership epoch and both rank build IDs changed. Storage `c72e2c…968ce` and numerical policy `0ae9c7…3bc74` retain exact declaration provenance. They are not independent current loaded-storage evidence.

## Root-only sequence

Use the exact argument arrays in `commands.json`, from this directory:

```sh
/usr/bin/python3 -B check_source.py
/usr/bin/python3 -B deploy_copy_only.py --rank 0
/usr/bin/python3 -B deploy_copy_only.py --rank 1
# Root performs the separately authorized purge/resource preparation.
/usr/bin/python3 -B preflight.py --rank 0
/usr/bin/python3 -B preflight.py --rank 1
/usr/bin/python3 -B run_physical.py
```

Run sequentially with no competing inference or compiler. Each copy verifies the frozen local manifest and all 14 source files, creates a closed tar payload, and uses the existing pinned SSH trust with `-S none`. The remote installer is the reviewed clean-MTP copy installer with only the fixed destination/schema strings changed. It refuses an existing destination, creates private files/directories (700 executables, 600 data/dylibs, 700 directories), fully rehashes every member, and launches nothing. The new tree contains the native, both resources, owner, four remote dylibs, complete four-file monitor closure, matrix and owner config. Copy evidence stays in fresh `copy-rank{0,1}-1` directories.

A copy timeout or failure is an unresolved deployment outcome. Inspect and retain the partial new tree and evidence before choosing a separately reviewed new destination; do not overwrite/retry blindly. The installer only observes the canonical empty journal. The later unchanged preflight independently takes the canonical flock, verifies all 14 hashes/modes and directories, requires no owner/native processes and empty evidence/journal, and applies the original resource screen. No journal is cleared.

The root should retain actual post-purge free-memory samples. Cut32's initial source-derived free requirement is 13,165,129,827 bytes per rank; merely crossing it does not establish that the later load will fit. The native performs its original current free/allocator checks and now reports the exact refusing operands. No parent floor or native limit was lowered.

## Ownership and evidence

`run_physical.py` and remote preflight differ only in the fixed remote root; 13 helper/input copies remain byte-exact. Original 300 s owner lifetime, 315 s controller timeout, bounded postflight observation through request origin +420 s, alias retention/restoration, resource monitors, process checks and canonical journal handling remain intact. Native cleanup, authenticated owner-release ACK, SSH transport termination, diagnostic EOF and postflight absence are separate proofs. The local controller already preserves late owner diagnostics through its bounded drain.

Retain raw controller records, decoded endpoint diagnostics, monitors, both postflight records, local owned-child termination, aliases and unchanged input pins. A load refusal is a diagnostic result, never a successful numerical comparison. If the request completes, the existing frozen registered comparator and successful reference remain the next gate; this package has read neither new candidate nor reference output.

## Checks and scope

`source-checks-2.json` records eight passing groups: all 65 upstream members, source/helper inverses, compact config/Ready framing, exact metadata/agreement changes, source-snapshot delta, complete 14-file tree hashes, installer/owned-helper inverses and Python 3.9 syntax. `checks-stdin-1/receipt.json` records one actual Python child consuming the explicit 131,344-byte stdin payload, exact output, empty stderr, exit0/reaped/group absence. Existing cleanup algorithms were not retested solely for constant changes. No native/GPU/model/remote execution occurred for these checks.

Root reviewed the prior parent and new binding/copy sources. The optional independent three-file copy review is pending; it is not represented as completed. `manifest.json` pins the local package; `run-pins.json` additionally pins external binaries/resources, trust and provenance. The source check is prospective and must precede any copy/preflight/physical evidence directories. `assemble.py`, `prepare_agreement.py` and `freeze.py` are retained preparation history, not repeatable deployment steps.
