# Qwen 3.8 Next (Flash-Next) qualification record

> Last updated: 2026-09-14 · commit `4e90ac8b`

This record summarizes native Qwen4 implementation checks on the affine-Q4
candidate. It contains no developer endpoint, credential, machine identifier
or personal workspace location. Passing implementation tests is not universal
model quality, hosted-provider certification or production deployment approval.

## Artifact and runtime scope

The canonical serving identifier is `DarkBloom/Qwen3.8-Flash-Next-Q4-mtp`;
the architecture is native `qwen4_exp` / `qwen4_exp_text`, not Qwen3.5 or27B.
The artifact retains131 shards,3866 indexed entries,501 vision entries,
75 embedded-MTP entries/31 trained-weight identities and384 learned-table
entries across128 parts. Quantization and SSD n-gram/PLE policy are unchanged.

The assessed executable SHA256 is
`b9ce85b352881ec076682f08e7a7367186163c7bc069a3461afbdcbf1f74462b`;
the matching metallib is
`2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2`.
Publication-only documentation, transport configuration and commit-metadata
cleanup do not alter model/runtime code. Any later numerical optimization
requires new affected-gate receipts.

## Recorded checks

| Gate | Result and scope |
|---|---|
| SDK default suites | 871 XCTest and1209 Swift Testing passes;12/14 explicit skips; no failures |
| Provider default suites | 102 XCTest and2906 Swift Testing passes;52 explicit skips; no failures |
| Native parser/envelope selection | 18 focused tests passed; no argument repair or malformed-call bypass |
| Standard API conformance | Chat12, Responses10, reasoning19 required plus one optional unsupported-high probe, invalid-control14 and multi-tool4 passed with MTP configured OFF and ON |
| Opaque channel transport | 16/16 complete transport cases preserve actual generated argument/reasoning bytes; requested-value fidelity remains separately failed |
| Matched OFF/ON output | 53 comparable successful responses match content, reasoning, tool arguments, finish reason and token counts |
| Media-cache mechanism | 14 reference and18 cached checks passed; image/video/mixed repeat reuse4096 tokens, changed-input misses, exact uncached-output/usage parity, history fallback and cancellation/readmission |
| Native video sampling | All20 synthetic frames retained, including the brief event at index9; this does not prove every downstream recognition result |
| Execution posture | Ordinary text speculates when eligible; constrained required/named text requests and media are target-only. Actual request counters, not head presence, establish engagement |

Two harness issues were corrected without weakening assertions: colocating
the source-matched Metal library before test execution, and draining the
asynchronous writer before advancing the TTL test's fake clock. The original
failures and causal reruns are retained in the qualification evidence.

## Remaining limits

Adversarial escaping/Unicode/literal-string copying, budget-exhausted reasoning,
brief-event recognition and strict plain-text formatting are not universally
correct. Invalid or incomplete forced calls remain rejected. Do not strip or
rewrite output to manufacture a quality pass.

Full original BF16 equivalence, every physical RAM tier, signed persistent-cache
restart, production account/attestation, hosted routing, release signing and
deployment need their own evidence and human authorization. The selected runtime
does not implement forced-tool MTP verification; its safety gate remains intact.

## Reproduction and related references

Use [the validation procedures](../../scripts/qwen38_validation/README.md)
with an explicitly approved target supplied outside the repository. Publish
only reviewed summaries, never raw request logs, environment dumps or credentials.
See [native support](../reference/qwen4-next-support.md),
[configuration](../reference/configuration.md#native-flash-next-candidate),
and [release procedure](../operations/provider-release.md).
