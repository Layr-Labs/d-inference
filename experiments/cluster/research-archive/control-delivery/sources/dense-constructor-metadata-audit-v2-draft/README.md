# Constructor metadata oracle V2

This source-only correction preserves `audit-dense-constructor-metadata-20260914.py` SHA `023187583131fddf7b287218a859395d60be97f55041fcf393371316bd65923c` unchanged. The original is also retained under `originals/`. Root's previous native and V1 audit receipts remain separate evidence.

V2 adds an exact `type(value) is int` guard for every integer field in the constructor report: top-level counts, arithmetic query-block count, source offsets/shape/bytes, full and compact constructor counts/shape/bytes, active and inert tensor metadata, and post-load summary counts. All original comparison functions and qualification limits remain unchanged after the one guard call at the start of `audit`.

The CLI now writes one exclusive new success or failure receipt. An audit refusal records `passed=false`, `status=failed` and `primaryFailure` and exits 1. It retains the complete stdout SHA once the bounded stdout read succeeds. An existing output is refused; input reports and earlier receipts are never overwritten. Failure to create/write the requested output must still be retained by the caller's execution wrapper. Successful receipts retain the original result fields and add `status=passed` and `primaryFailure=null`.

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/dense-constructor-metadata-audit-v2-draft/audit_dense_constructor_metadata_v2.py \
  --stdout /path/to/completed-constructor/stdout.jsonl \
  --output /path/to/new-constructor-metadata-audit-v2.json
```

The fixed retained metadata fixture and its original raw pin are unchanged. No candidate report or actual retained fixture was read while preparing V2. Nine invented CPU tests pass, including 32 Boolean substitutions spanning every integer field category, malformed shape/byte metadata, structured parse/type failure retention, refusal to overwrite and unchanged-comparison AST checks. The success-publication test mocks the comparison result; it does not qualify model metadata. Tests prohibit real subprocess/native/socket calls.

This remains a metadata oracle. It does not independently replay safetensors header offsets, stage Plan serialization, physical native release, parameter values, model numerics, peak memory or throughput. The added integer guard is not a new closed schema or resource-admission framework. Root owns actual saved-report replay and its new receipt.
