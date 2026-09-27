# GPT-OSS: matched contiguous quality control

> Last updated: 2026-09-07 · commit `e7f9c53ee`

All eight GPT-OSS responses reproduce the earlier Paged Attention outputs exactly when run with contiguous attention. This closes the migration-specific investigation for these four fixed tasks. The generated-code failure and incomplete answers remain recorded as model/task limitations.

## Matched comparison

The verified 0.9.0 runtime runs the four unresolved code/prose tasks from the [quality follow-up](2026-09-07-five-model-quality-followup.md): fractions, functools, Alice and The Time Machine. Both repetitions retain the same complete request, canonical prompt tokens, September 7 prompt date and 1,024-token budget. SSD caching and MTP are disabled on both sides. Actual execution resolves to contiguous attention without fallback.

Every matched pair has identical full prompt arrays, generated token arrays, output text and finish reason. All eight responses reach the configured length limit. Exact equality is observed evidence here, not a new universal release requirement.

| Task | Two-response result on both backends |
| --- | --- |
| Fractions continuation | Failed: the completed hash method hashes a numerator/denominator tuple, violating numeric hash compatibility. Final code then truncates inside equality handling. |
| Functools continuation | Inconclusive completion: repetitive analysis reaches the cap without the requested final code. |
| Alice continuation | Inconclusive completion: repetitive analysis reaches the cap without the requested prose. |
| The Time Machine continuation | Inconclusive completion: repetitive analysis reaches the cap without the requested prose. |

The executing reviewer and root independently read all four distinct outputs in full. The two failed and six inconclusive task observations are preserved; identical poor outputs do not become successful answers. The same concerns occurring identically on contiguous attention establish no Paged-Attention-specific regression in this bounded comparison. Earlier successful arithmetic and tool responses remain separate capability evidence.

## Execution and evidence

The one-job run completes in 145.4 seconds with eight response rows and seven native controls. Actual width, prompt identity, tenant isolation, cancellation/recovery, accounting and process retirement checks pass. All request, active-token and KV reservations drain. Source, runtime and model audits match before and after execution; the clean host observation finds no remaining owned or unexpected processes.

Collection verifies all 326 original files, with no excluded prefix-cache files. The owner retains the original 4,422,484-byte remote archive and its hash. The selected projection does not claim to rehash that full archive or preserve its original file modes.

The [result summary](evidence/gpt-quality-control-2026-09-07/evidence.json) separates structural success, exact comparison and retained semantic outcomes. The [publication capsule](evidence/gpt-quality-control-2026-09-07/evidence.tar.gz) includes original reports from both runs, inputs, metadata, audits, retirement records, runtime identity and both manual reviews; its [manifest](evidence/gpt-quality-control-2026-09-07/manifest.json) binds every member. This control establishes neither universal model quality nor cache routing, persistent restart or complete release acceptance.

Related: [final build](2026-09-07-release090-final-build.md), [sustained workload results](2026-09-07-five-model-sustained-final.md), [acceptance criteria](../design/release-090-acceptance.md).
