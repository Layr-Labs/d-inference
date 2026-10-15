# Gemma stage plumbing candidate

Source-only implementation, not yet compiled. No MAIN files changed. No model construction, payload reads, full-weight hashes, remote operations or native execution occurred.

`runtime.patch` adds eight Foundation-only Runtime files. `integration.json` lists their destinations and hashes. `INTERFACE.md` gives the native boundary. The retained artifact is Gemma 4 26B QAT with 30 original layers and explicit split expert tensors; the plan admits cuts 1 through 29.

Expected metadata totals are 1,339 unique selected tensors / 14,467,688,508 bytes, 358 excluded vision tensors / 1,140,925,536 bytes, and 1,342 destination tensors / 14,882,924,604 bytes. The extra 415,236,096 bytes are the exact tied-embedding replica. These are header-derived logical payload values, not allocation or physical-fit evidence.

The model-free compile closure is 24 Swift files: eight new files, ten baseline files and six fixtures. Nine baseline files are unchanged MAIN sources. The tenth is the exact existing CheckpointManifest declaration plus its Foundation import, extracted only to keep the fixture independent of the file-backed checkpoint reader. Product integration uses the existing DTO. `preparation-input-pins.json` binds source origins and retained expected vectors; `compilation-snapshot.json` binds the complete compile/input closure.

After an explicit root compiler-slot grant, run:

```sh
python3 /Users/developer/DarkbloomDev/cluster-research/gemma4-stage-plumbing-draft-20260915/Tests/run.py --output /Users/developer/DarkbloomDev/cluster-research/gemma4-stage-plumbing-checks-1-20260915
```

The runner creates a fresh private module cache, uses Swift 6 with warnings as errors and at most two jobs, bounds compilation to 60 seconds and execution to 10 seconds, and retains stdout/stderr, process-group and source-revalidation receipts. The fixture has its own 10-second alarm through final output. Diagnostic files are checked against a 1 MiB cap after exit; that is not an in-flight IO cap.

Fixtures cover all 29 retained cut/count/byte vectors, every cut's original/global geometry and attention phase, all 1,339 cut-15 source/destination vectors, local quantization relocation, malformed coverage/replication/global index/geometry/quantization, and unchanged 9B cut-4/cut-16 plus 27B cut-32 Qwen Plan/stage fingerprints. Qwen's old exclusive mappings are also projected through the new conservation type without altering their original identity.

Compilation and fixture results are pending. Independent mapper review is pending at this source freeze. Native construction, payload verification, resource fit, dtype attestation and numerical/generation qualification remain separate work.
