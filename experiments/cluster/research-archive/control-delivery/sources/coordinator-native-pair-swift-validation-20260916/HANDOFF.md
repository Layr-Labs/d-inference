# Member and public native-pair Swift qualification

This source-only wrapper composes the exact 25 Swift files from member freeze
`4ae431c6…ef965`, followed by the two Swift files from native-pair B freeze
`69189730…dc500`, over current dirty MAIN. There are no overlapping Swift paths.
The B cancellation correction changes only Go files and is outside this Swift
composition. The original member wrapper `0550d8fb…2be06`, both product freezes,
and every existing preparation or failure remain unchanged.

`swift-integration.json` contains all 27 source paths, exact preimages or required
absences, and final hashes. `source-context.json` adds the four package files and
three shared protocol source pins. The five existing anonymous metallib binder
pins and review are retained verbatim. The wrapper verifies every member of both
product freezes and the upstream wrapper, but checks MAIN preimages only for this
Swift scope; separately integrating the qualified Go files cannot invalidate it.

The original inventory, owned-process, and check-process helpers are byte-exact.
Preparation still copies the four local package trees with bounded APFS copy,
compares their complete source/dependency inventories, retains the old SwiftPM
workspace-state bytes, relocates only private metadata, and preserves the copied
path-bound ModuleCache before rebuilding. It applies only the 27 declared files
and compares the complete candidate inventory before and after each child. The
full source/cache inventory is deliberately deferred to the granted preparation,
so this source freeze performs no cache scan or materialization.

The existing Swift filter is unchanged apart from `|NativePairMessageTests`.
Completion now requires actual Swift Testing pass lines for both B methods:

- `publicSigningBytesMatchIndependentGoAndPythonFixture`
- `ambiguousOrUnknownPublicRecordsAreRefused`

It also requires the existing member lifecycle cases and CLI role-selection case
to pass, including the parameterized real WebSocket negotiation test's display
name. A discovery/start line is insufficient. The existing legacy CoordinatorClient,
startup preload, supported-set, session-factory, and metallib cases stay selected;
the full selected test command must exit naturally with zero status. The actual
`darkbloom` build requires the matching attempt's successful test receipt.

Swift remains `-j 2`, with disabled automatic dependency resolution and build
manifest caching; each test/build child has the inherited 900-second parent
bound, 4 MiB diagnostic cap, and 512 MiB process file ceiling. Owned children
must be reaped with their process groups absent. Existing environment isolation
is unchanged. No Go phase exists in this wrapper.

After explicit compiler/materialization grant, run sequentially:

```sh
cd /Users/developer/DarkbloomDev/cluster-research/coordinator-native-pair-swift-validation-20260916
/usr/bin/python3 -B prepare.py --phase swift --output /Users/developer/DarkbloomDev/cluster-research/coordinator-native-pair-swift-build-1-20260916
/usr/bin/python3 -B run.py --phase swift-tests --prepared /Users/developer/DarkbloomDev/cluster-research/coordinator-native-pair-swift-build-1-20260916 --attempt 1
/usr/bin/python3 -B run.py --phase swift-build --prepared /Users/developer/DarkbloomDev/cluster-research/coordinator-native-pair-swift-build-1-20260916 --attempt 1
```

Inspect the preparation receipt before the compiler step. Each directory is
create-only; retain any failed preparation or compiler output and use a new
reviewed attempt. The CLI build records the actual binary hash and size without
executing it. No source/runtime changes, model weights, remote machines,
coordinator deployment, native owner launch, or RDMA enablement are involved.
These checks do not qualify provider invocation of the native grant/key flow.

Source validation consists of Python AST, the exact preserved helpers and
preimages, the filter extension, and small fabricated completion-parser controls.
No Swift compiler, actual Swift tests, preparation, or payload copy has run here.
