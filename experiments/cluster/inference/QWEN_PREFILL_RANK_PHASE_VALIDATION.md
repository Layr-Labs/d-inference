# Serial 8K rank phase validation

> Last updated: 2026-09-14 · commit `e4df336bc`

The registered Qwen3.5 9B serial rank diagnostic passed its numerical and local
phase audits with two processes on one 24 GiB M4 Pro. The 16-layer stages had
similar observed compute-call costs. This supports investigating the split;
it does not establish two-machine throughput or GPU overlap.

## Workload and result

The fresh request used 8192 prepared prompt tokens, 512-token chunks, one output
token, `serial_v1` and BF16 stage activations. The executable was
`1d373d352a3f580043cbd6e20d354d6b1b8085ffc10e07874b5bd7bf9a5425ce`.
Model, raw prompt and arithmetic match the
[earlier numerical controls](QWEN_LONG_PREFILL_RANK_VALIDATION.md).

Both native processes exited successfully with their expected two JSON records
and one loopback warning. The unchanged numerical audit validated all sixteen
frames, the final state and logit metadata/digests, and selected token 271
against the separately frozen full-model reference. Opaque candidate state and
logit commitments retain the earlier audit's limits.

| Local clock scope | Observed time |
|---|---:|
| Rank 0 fresh request through returned first token | 18.784448750 s |
| Rank 0 sixteen prepare calls | 9.372237458 s |
| Rank 1 sixteen consume calls, including final selection | 9.314684249 s |
| Rank 0 consumed-acknowledgement waits and validation | 9.318295294 s |
| Rank 1 header receives and validation | 9.410853544 s |

The request interval corresponds to 436.105 prompt tokens per first-token
second. Each table row uses only its own process's clock. Receive/wait spans
include peer compute under serial scheduling; they are not network transfer
times. Prepare/consume spans include CPU work, checks and observer overhead,
and do not isolate GPU kernels. The local phase audit does not sum or align
rank clocks. This single instrumented run has no causal speedup or recorder
overhead qualification.

## Evidence and limits

The sidecars contain exactly 204 rank-0 and 235 rank-1 events. The frozen
72-test phase auditor checked their full recorded-request identity, exact
source-derived action order, monotonic frontiers/timestamps and local interval
arithmetic. The sidecar reader was frozen before its authors accessed these
candidate records, after native execution had completed; the phase auditor
was frozen before the rank invocation.

All 24 collected memory samples reported pressure level 1 and zero swap.
Launcher SSH clients and the two later read-only sidecar SSH clients were
reaped. These launcher/retrieval checks do not provide an independent complete
runtime-provenance audit or remote `waitpid` evidence.

| Retained artifact | SHA-256 |
|---|---|
| Native launcher receipt | `a500416181e229ab9d33e0e7b9f72084b242e5a5b4aa6e47d03cf83db53e8491` |
| Independent numerical audit | `06020d881b9060342fb49edeffc17dffe4c15b4204b70c3b1c8706b0463d9a0a` |
| Both sidecar retrieval receipt | `568368bc1f8718ef090314372d632233bae6f3a6d9ddb9238e4abc8ecb431bc2` |
| Independent local phase audit | `8126c34e021dc5814146e377916bf8c9e307fda89d883a4eb40fd9f3af092617` |
| Phase audit execution receipt | `46bc25991983ce9692f1e6f6986ea327303009adf753ccca465ba1c5367717b0` |

The [phase trace contract](QWEN_PREFILL_PHASE_TRACE.md) describes the event
boundaries. The [solo phase diagnostic](QWEN_PREFILL_PHASE_VALIDATION.md)
provides a separate whole-model observation. Neither run qualifies physical
Thunderbolt/RDMA transfer, target M3 Ultra hardware, 27B performance or public
launcher execution.
