# Public short-ledger support handoff

Outside-Git support only. The root integrated the five frozen core files and two
fixture files unchanged. Its standalone Swift 6 warnings-as-errors run passed
31 accepted/42 rejected checks, with both stderr files empty. Root's execution
receipt is `32f6072897a57552cfc070ce1d5fc1e31d7fff6c04e7690b84b2def821682c8b`;
stdout is `8d99d1e545b5d91095e06f34a626f2a3573108e4e9caa42cff595c0798d1ecad`.
This support package has not executed its public runner or any compiler/native job.

Integrate the new QWEN_DENSE_SHORT_LEDGER.md and relative-path run.sh from
`proposed/`, then apply `docs.patch` to the pinned README/developer-test bases
(or copy those two proposed document versions once). No Swift or metadata
fixture is duplicated. The sole retained stdin remains
Tests/RegisteredDenseProfiles/retained-inputs.json.

`source-map.json` binds the exact 21 source inputs in root's proven order, their
integrated hashes, shared stdin and both document bases. The script uses an owned
temporary compiler directory with EXIT cleanup and an optional production-source
directory argument. The documentation keeps standalone success distinct from
public-runner execution and native forward qualification. It centralizes Q's
state/fusion/workspace/CPU evidence scope so later full-reference owner docs can
link it and focus on actual OS/resource/ownership admission.

Author checks are source/path/link/patch comparison and bash syntax only. Root
owns public-runner execution and repository-wide doc checks. No provider or
coordinator admission policy, legacy gate, CLI or native operation changes here.
