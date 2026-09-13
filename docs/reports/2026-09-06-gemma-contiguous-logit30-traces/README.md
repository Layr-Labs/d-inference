# Gemma contiguous position-30 raw evidence capsule

> Last updated: 2026-09-06 · commit `a34ef5944`

This additive capsule preserves every one of the 137 payloads named by the original execution-results manifest. The original report and its banked manifests remain byte-identical. Both bounded trace analyses reproduce exactly from the capsule on CPU, without model binaries, model weights, a test host or private keys.

- [Original trace report](../2026-09-06-gemma-contiguous-logit30-traces.md)
- [Raw evidence archive](raw-evidence.tar.gz)
- [Archive manifest and explicit exclusion accounting](raw-evidence-manifest.json)
- [Independent verification and analysis-reproduction script](verify_raw_evidence.py)

The archive contains 138 regular files: all 137 source payloads plus a self-copy of the frozen execution-results manifest. It includes both native reports, engine logs, telemetry, inputs, event and terminal receipts, original control reports, analyzers, the prepared/activated source packages, and the preserved failed prelaunch attempt. No source-manifest entry is excluded. Native runtime executables, metallib, weights and private-key payloads were never part of that manifest; their recorded paths, settings and identity hashes remain available. The two nested staging archives contain source and evidence, and were inspected separately.

Archive SHA256: `013c33518147eb7362e803f27c20545cafc1608f2b033668e4e20100e58dbd57` (639794 bytes). Source manifest SHA256: `372f7a6434a42308504d1a05b59d4f1dadb82d1bbfea4dba5e8320bd4ac1e8ae`. Archive entries have normalized timestamps, owner fields and read permissions; original bytes and SHA256s are preserved.

Run the following from the repository root:

```sh
python3 -B docs/reports/2026-09-06-gemma-contiguous-logit30-traces/verify_raw_evidence.py --reproduce-analysis
```

The script checks every entry against both manifests, rejects unexpected, missing, duplicate and unsafe entries, then extracts into a temporary directory and uses the preserved original trace/control analyzer. It compares the reproduced results to the banked analysis. It performs no SSH, model run or runtime build. Successful reproduction validates the recorded observations; the automatic-versus-ordinary correctness failure and the original unobserved full-state limitation remain unchanged.
