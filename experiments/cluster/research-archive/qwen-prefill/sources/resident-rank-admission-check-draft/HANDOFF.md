# Resident rank admission fixtures

> Last updated: 2026-09-14 · commit `e4df336bc`

Copy the two proposed Swift files into the existing ClusterInference source
directory and apply the one-call `Main.patch`. The check uses the actual
`Options(arguments:)`, `QwenRegistered9BLongPrefillReferenceAdmission` and
`QwenLongPrefillResidentRankAdmission.validate` implementations. No validation
logic, Options substitute, source receipt or native owner is duplicated.

The helper embeds the exact 3,118-byte registered 9B configuration already used
by the public profile fixture. Its decoded bytes are checked against the same
configuration SHA before use. All prompt data is constructed as bounded CPU
integer arrays; model and token paths supplied to Options are unused sentinels.
No filesystem preflight, process environment read, model/Collective creation or
MLX initialization occurs in the new check. The existing adapter branch returns
before the first `MLXArray` initialization in Main.

Expected new JSON record: `qwen_long_prefill_resident_rank_admission_check`,
with four accepted and 35 rejected named cases. This is prospective until root
compiles and runs the adapter target. The old 38 records remain an unchanged
subsequence; the new call adds one record without changing their sources.

- Four accepted cases: one request; fresh A/B/A identities with one warmup;
  maximum 16 requests leaving one measured request; omitted/default half plan.
- Sixteen cohort rejections: bounds/warmups, initial epoch, UUID/epoch reuse or
  mismatch, malformed epochs, initial prompt/artifact pins and selected-plan
  substitution, including nil versus unequal plan.
- Fourteen direct real-Options mutations: both trace paths and existing
  workload, timeout, execution, mode, transport, teacher and precision gates.
- Five unchanged local-constructor rejections: wrong raw configuration,
  artifact or prompt pin, a noninteger JSON token and an out-of-vocabulary token.

The last group fails before a typed local admission can be assembled. The
fixture does not manufacture malformed copies of closed admissions merely to
reach later guards. Valid distinct prompt histories remain permitted, and the
fixture does not equate a repeated history with a repeated UUID or wire epoch.

The source-only review and pin checks do not establish model reuse, native
retirement, concurrency execution, current resource availability or throughput.
Root owns full-target compilation and execution. There is no need to extract a
second pure Options parser or compile its broad dependency tree separately.
