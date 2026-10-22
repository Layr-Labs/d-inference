# Memoization numerical non-regression

PASS against the previous local MTP run: all four complete 262,144-value final rows, all 360 final state components (128,860,640 bytes per arm), all 64 generated IDs and each request's verification widths, accepted prefixes, proposal count and seed-step count are exact. All 728 sidecars were read with native dtype/shape/frontier/hash and file-identity validation. Both actual physical comparison receipts, compiled native/source/package identities, raw resource observations and original process/journal retirement were joined. The target and auxiliary admission charges are unchanged.

This compares EAEB local MTP against FFB8 local MTP. It does **not** qualify MTP against ordinary generation. The retained ordinary comparison still fails with final-row relative RMS 0.11180286017825311 (11.18%), despite matching generated IDs. No tolerance or numerical gate changed.

The bounded read-only child 71830 completed naturally with exit0 in 6.933 seconds, was reaped, left no process group and emitted no stderr. No compiler, native model, GPU or remote execution occurred. The first attempt's empty-source-file preflight failure is retained in the sibling `memo-numerical-nonregression-actual-1`; the correction permits only source-manifest-declared empty files and changes no numerical assertion.

- Result: `comparison.json`, SHA256 `c23d9c9e740d459b6d03135aa0c828edc81aae8946c5cd4161f2b329db2994f8`.
- Actual invocation/retirement: `receipt.json`, SHA256 `9c213194ce5199d57c137a43ff2e0a3685679089a136868a3be26dbcf0ca2f9c`.
- Comparator successor source: `memo-numerical-nonregression-empty-source-fix/source-inputs.json`, SHA256 `5045f18051eb293fa23a88ec3f2cabe6f598b6f4219a491d69f4ebca1ef12287`.
