# Closed native cohort-readiness fixture

> Last updated: 2026-09-14 · commit `e4df336bc`

This out-of-tree proposal adds three Swift files and replaces Options/Main.
`runtime.patch` is based on the integrated 40-record cohort build. Existing
adapter order stays intact; the new call is
`try checkQwenLongPrefillCohortReadinessAdmission()`. Expected total: 41 records.
No Swift/compiler/native/SSH execution was performed by the author.

After root integration, the new mode accepts exactly these five distinct pairs,
in any order, with no other options:

```text
--mode qwen-long-prefill-cohort-readiness-check
--transport loopback-test
--epoch HEX32
--cohort-readiness-case match|warmup-mismatch
--timeout-seconds INTEGER_1_THROUGH_30
```

The epoch must use the existing exact lowercase 32-hex rule. Timeout text must
match the canonical integer representation. Missing/duplicate/extra pairs,
model or token paths, synthetic/workload controls, traces, source/Plan options
and precision overrides fail before native setup. Other modes reject the new
case flag before their admission adapters. Direct typed Options callers receive
the same mode, field and timeout checks.

The entry reuses the exact retained 9B configuration and bounded synthetic A/B/A
prompt helpers. It creates three fresh request identities deterministically
bound to the supplied run epoch: the first equals that epoch; the others use a
separate SHA domain plus ordinal. Existing typed admissions verify UUID/epoch
consistency and uniqueness. Both rank descriptors are admitted before MLX or
Collective creation. No unverified environment rank selects a descriptor.

The match case uses warmup counts 1/1. Warmup mismatch uses 1/0 and keeps all
other descriptor content identical. The run function selects from the actual
validated Collective rank and calls the already frozen resident readiness
wrapper. It performs no loader call, model forward, request execution or timing.
Its metadata fixture is not actual arithmetic/resource or payload admission.

On success, Main emits one JSONL record per rank, only after the exchange and an
outer native-error check. The record contains:

- `kind: qwen_long_prefill_cohort_readiness_check`, `schemaVersion: 1`,
  `epoch`, `fixtureCase`, `rank`, `worldSize: 2`, `transport: loopback-test`.
- The exact `cohortAgreement` descriptor and `cohortReadiness` receipt.
- `postAgreementMarker: reached_without_model_load`,
  `readinessExchangePassed: true`.
- `modelConstructed`, `weightsMaterialized`, `requestsExecuted`,
  `modelPayloadRead` and `requestStateCreated`: all false.
- `arithmeticEnvironmentIsFixture: true`; actual artifact/resource verification,
  resident reuse, physical transfer and throughput qualification: all false.

The encoded record must be smaller than 65,536 bytes before its terminating
newline. There is no earlier stdout record. A success marker alone does not
prove successful process exit or parent cleanup; the driver must require those.

On the intended mismatch, rank1 returns through Main with the exact diagnostic:

```text
cluster-inference: Resident ranks disagree on ordered requests, warmups, source or policy before stage load
```

The existing source-bound loopback warning is also present. Rank0 can remain
blocked waiting for a reply; whole-cohort parent cancellation remains required.
An unexpected native error or early failure is not the intended mismatch proof.
There is no new retry or blocking cleanup fence in the native failure path.

The private driver should run match, warmup mismatch and a separate missing-peer
topology using the match case. For the last case retain both configurations but
start only rank0; it qualifies bounded startup cancellation, not loss of an
established connection. See the preceding frozen cohort package's
`NATIVE_QUALIFICATION_PLAN.md` for guard and evidence scope. The driver must pin
the newly built binary, not reuse the preceding binary merely because it passed.

The prospective CPU adapter fixture has 3 accepted CLI cases, 42 rejected cases
and 5 identity invariants. It uses actual Options and typed local admissions,
checks both pre-native intents, isolates the warmup-only difference, preserves
two independent run-epoch SHA vectors, and rejects invalid native rank indices.
No native exchange runs in the adapter branch. Source checks and six source
mutations passed; `git apply --check` passed read-only. The retained first source
assembly attempt stopped on an indentation anchor only; no Swift test ran then.
Root subsequently requested aligning that inherited adapter call from eight to
twelve spaces. The explicit `whitespace-alignment.patch` and pins retain this
format-only correction; the earlier source checker/receipt remain archived.

Arithmetic's separate constructor-probe Main branch is before Options parsing;
this proposal's two Main hunks are after Options parsing and do not overlap it.
Root should preserve both when integrating the independent drafts.
