# Authenticated remote owner first slice

Ready: four new pure Swift files plus 15 targeted fabricated lifecycle tests.
`DESIGN_ADDENDUM.md` records the approved first product transport: installed
Darkbloom remote owner over explicitly pinned/authenticated SSH stdio, with a
typed endpoint permitting TLS later. It includes concrete native bootstrap,
ownership, capacity, recovery and original-deadline integration requirements.

The state API is `ClusterOwnerBinding`, `ClusterOwnerLeaseState`, typed control
intents/actions and value-only status/terminal DTOs. It has no wire codec, SSH
launch, authentication, native process, model allocation, durable device lock
or orphan recovery implementation. Six exact existing Protocol sources are
pinned copies. Existing direct-child, provider and native runtime files are unchanged.

The independent review and root both found that failed retirement could restore
readiness after resource release. The final source quarantines **both failed and
cancelled** retirement, matching the current native session/facade. The added
regression proves release does not permit a new request, while subsequent actual
native exit and device cleanup still complete. Late real admission/retirement
observations remain recordable. CPU-v1 and its two relevant source originals are
retained as historical pre-correction evidence.

Final validation: `xcrun swift test --jobs 1 -Xswiftc -warnings-as-errors`, exit 0,
15 tests, no failures, 1.348 seconds total; all compiled input pins unchanged.
SwiftPM stderr contains ordinary build progress and no compiler diagnostics.
Receipt: `records/cpu-2/execution.json`, SHA256
`34816ab5eaeb4f51842db8475a4b11e284788352139c6aee6be978734a9cf6e9`.
Test stdout SHA256
`fd5ea23987c53dc684493e039a03551eb8de3ee94437c03ccc269892a72f53ec`.

Independent final source review:
`../cluster-remote-owner-source-review-draft/source-review.json`, SHA256
`dc7c0c07ca45896f216fe1637eb94c92e576f0f50b5f63488202523c72e66fcd`.
The reviewer read all four runtime files and 15 test bodies without execution;
the non-clean retirement finding is resolved. Root accepted the correction.

Next implementation is the endpoint interface and mechanical Pair/Request
factoring, based on the separate deadline overlay so its lifetime and admission
caps are retained. Then implement the installed SSH owner/service and authenticated
native bootstrap binding. No actual remote execution or performance is proven here.
