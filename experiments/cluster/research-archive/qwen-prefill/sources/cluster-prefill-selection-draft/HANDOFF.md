# Explicit product prefill selection

The private overlay adds a saved, capability-checked choice between `serial_v1` and `one_chunk_lookahead_v1`. Serial remains the default. It uses the ordinary serving path and the existing lookahead scheduler and allowance; it adds no diagnostic capture, serving environment override, request concurrency, or memory-floor reduction.

Promote the 31 files in `integration.json` / `integration.patch` against `base-pins.json`. The patch applies read-only to the current MAIN sources. Package manifests, generation wire messages, native math, window/transport implementation, resource policy and ordinary solo configuration are unchanged. `QwenGenerationPrefillPolicy.swift` has only the reviewed comment correction from “stays serial” to “defaults to serial.” The new files use existing target source discovery.

## Contract and compatibility

- Protocol `ClusterPrefillSchedule` supplies the closed names. The canonical capability optionally advertises `supportedPrefillSchedules`; omission is the legacy serial-only contract. The old 3704-byte descriptor still decodes and re-encodes byte-for-byte. The native metadata producer and admission share `QwenResidentAdapterDefinition.supportedPrefillSchedules`.
- Setup JSON accepts `prefillSchedule`. Omission decodes as serial while retaining old saved canonical bytes. Every new `configure` save writes the chosen value explicitly. A known schedule absent from the pinned capability is refused; null, unknown names and arbitrary environment/capacity inputs remain refused.
- `DistributedInstalledPrefillSelection.workerArguments` omits the flag for serial, preserving old pinned workers' exact argument surface. It emits `--prefill-schedule one_chunk_lookahead_v1` only after advertised support is checked. `WorkerConfiguration` accepts the closed optional pair, with omitted serial default and the unchanged complete bootstrap triple requirement.
- `QwenResidentLoadConfiguration` holds the immutable schedule. Native admission validates adapter support and binds nonserial selection into the bilateral load fingerprint before either stage is loaded. Existing serial load material remains identical. Generation agreement still binds the selected native policy.
- Loaded readiness includes the maximum existing prefill allowance only after live OS/allocator admission. Serving reserve derives the actual request allowance, requires base plus extra to fit both the actual Ready ceiling and owner ceiling, and stores the policy/allowance. Execute rederives it and keeps the charge through normal retirement/publication. Rank0 retains the extra allocator-bounded boundary plus host copy/bookkeeping; rank1 and one-chunk requests retain the existing bookkeeping charge. This is named allocation accounting, not a whole-process peak guarantee.

Old saved setup can continue with its old pinned serial worker. Selecting lookahead requires a worker built from this implementation, its freshly generated/pinned capability, and matching member setup. A source declaration alone does not authorize a model load or provide available capacity. Mismatched member schedules fail native pre-weight agreement; this overlay does not synthesize a new Plan or a Ready receipt.

## Verification and reviews

`checks.json` binds all retained receipts. Direct Swift 6 warnings-as-errors Foundation checks passed:

- Protocol canonical/closed capability tests plus the unchanged seven original protocol groups.
- Actual pure native metadata production against the retained model/profile/Plan oracle and five fabricated CPU metadata-command children.
- Configuration schema/store tests and nine actual-file groups, including old immutable saved-record loading and explicit new-save selection.
- Public/native mapping, load-agreement material, both-rank/single-chunk charges, allocator/overflow/capacity refusal, prompt-only frontier drain, and worker CLI admission (9 accepts / 29 rejects).

The initial four runners passed in 16.12 seconds. After root found that an unconditional new flag would break old serial workers, the corrected installed-argument regression passed in 4.680 seconds. The additional actual legacy Store.load check passed in 3.786 seconds. All stderr was empty and checked source pins stayed unchanged. The earlier review input is preserved as `review-before-serial-argv-correction.patch`.

Arithmetic's independent native-serving source review is `native-source-review.json`, SHA `e37c7a0b6512f80a19a13056d95bd907406d5870b6f7452d54d0bdd1309b2124`; all six reviewed functional native files and its four supporting files match. Root reviewed Protocol/config and native coupling, found the resolved serial-argument compatibility issue, and owns final combined integration review. The comment-only correction is separate from those functional pins.

The runtime XCTest adds actual `QwenResidentAdmission.loadAgreementFingerprint` comparisons for both equal policies and peer disagreement. That XCTest, the complete native owner typecheck, full Provider/CLI build, and physical product lookahead execution have not run in this task. Root owns those checks. No new numerical or performance qualification is claimed.

The five requested documentation changes are included. The two edited docs pages pass the exact repository docs checker in the private source view. Root-owned `docs/developer/build.md` and `docs/developer/test.md` are untouched.

## Hookup map

| Boundary | Implementation |
| --- | --- |
| Advertised adapter support | `ClusterRuntimeCapability*`, `QwenResidentAdapterDefinition`, `QwenResidentCapabilityMetadata` |
| Saved choice and immutable record compatibility | `ClusterConfiguration`, `ClusterConfigurationCodec`, `ClusterConfigurationStore` |
| Installed launch, old serial arguments | `DistributedInstalledPlan`, `DistributedInstalledPrefillSelection` |
| Closed native startup | `WorkerConfiguration`, `QwenResidentLoadConfiguration`, `QwenResidentAdmission` |
| Actual readiness/reservation/execution | `QwenResidentRuntime+Load`, `QwenResidentRuntime`, `QwenResidentPrefillSelection` |

After promotion, root should run the normal full Provider/CLI checks and build the native worker with the existing deployment/metallib checks before invoking the new capability command. Native admission XCTest and matched physical serving checks remain separate from the Foundation results above.
