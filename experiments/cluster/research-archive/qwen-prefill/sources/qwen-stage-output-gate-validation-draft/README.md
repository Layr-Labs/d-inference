# Experimental output-gate metadata validation proposal

Source-only proposal, 2026-09-14. Root owns integration, compilation and execution.
No repository, library, provider, runtime/resource admission or operator change
has been made by this draft.

`metadata.patch` changes only the experimental `QwenStageMetadata.validate`:

| Declared `text_config.output_gate_type` (or flat text key) | Result |
| --- | --- |
| Absent | Accept the existing fixed SiLU operation |
| Exact string `swish` | Accept that existing compatible operation |
| Exact string `silu` | Accept that existing compatible operation |
| Any other string, including case/whitespace variants | Reject |
| Null, Boolean, number, array or object | Reject |

The known-key addition is paired with a value/type guard. It does not remove or
normalize the property. `QwenLayerStagePlan` continues to bind the original input
bytes and preserve the declared spelling in the per-stage configuration, even
though the two admitted spellings describe the same operation.

The provider's `Qwen35TextConfiguration` **still ignores this key**. The existing
GDN gated RMSNorm hardcodes SiLU; this experimental validation permits only source
declarations compatible with that implementation. It adds no configurable model
operator. Full-attention sigmoid remains separate and unchanged. The primary
source audit is frozen in `../qwen27-output-gate-audit-draft`, manifest SHA-256
`7c88a69a1fd93f9f3563d1ea59111a60eede5b4fa95222b85b85a58e565c8848`.

Gate acceptance can make the exact 27B configuration eligible for **metadata-only
candidate enumeration**. It does not supply missing weight payloads, admit its
15,132,802,048 declared canonical source bytes under the current 6 GiB ceiling,
relax registered-9B/16+16 execution contracts, or alter `apple_m5`/`mlx_nax` provider
eligibility. Numerical parity, M3 capability and performance remain unqualified.

## Proposed fixtures

`QwenStageOutputGateMetadataCheck.swift` is a Foundation-only fixture taking
caller-owned configuration bytes and legal ranges. It returns an Encodable result;
it performs no file IO or model work. Per invocation it expects three accepted
policy cases and fifteen rejected declarations. It checks exact input retention,
unchanged spelling/absence in both stage configurations, and distinct source-bound
plan fingerprints. Negative cases must fail at the new output-gate guard.

The caller can invoke it independently with:

- retained 9B config and `[0..<16, 16..<32]`;
- retained 27B config and `[0..<32, 32..<64]`;
- a public synthetic wrapped or flat configuration for reusable repository tests.

Removing a key inside `configured(nil)` fabricates an explicit missing-field test;
production validation never strips a checkpoint property to obtain admission.
The fixture remains uncompiled and unexecuted in this draft.

The previously frozen candidate fixture expects `swish` to be rejected. Its old
receipt remains valid evidence for the old implementation. The separate
`candidate-fixture.patch` changes only that negative declaration to `sigmoid`;
the full proposed replacement file is supplied too. Root should use a fresh output
directory after integration and preserve the completed pre-change fixture run.
Do not overwrite the frozen original in `layer-stage-candidate-plan-draft`.

For the exact 27B enumeration, retained
`models/Qwen3.8-27B/weight-layout.json` has a `tensors` dictionary with 2,211 names.
Its 1,847 `language_model.` keys are the text name fixture; the other 364 belong
to vision/MTP. `canonical-27b-name-fixture.json` supplies these names under
`canonicalSourceNames`, preserving each string without renaming and binding the
source file hash. It is a header-derived name fixture, not a claim of constructed
model inventory, descriptor validation or verified payload contents. The existing
`Plan.parameters` check still validates the supplied names during enumeration.

## Frozen draft contents and checks

The original metadata snapshot is supplied beside the proposed file. The Python
preparation script verifies that its only metadata edits are the known-key addition
and local value guard, and that repository and frozen fixture inputs remain byte
identical. It does not execute Swift. Independent transport-agent source review
found no concrete blocker; no tests or models were executed by that reviewer.

Root may apply `metadata.patch` at the repository root, place the new fixture in
its chosen pure-test target, and apply the one-line candidate fixture change at
the already-integrated test location. These are handoff instructions only: no patch
application or build was performed by this agent. Existing base JSON schemas and
all native numerical/ownership/transport contracts are unaffected by the proposal.
