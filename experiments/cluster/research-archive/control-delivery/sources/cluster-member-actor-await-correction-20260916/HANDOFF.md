# Member timer actor-hop correction and private retry

The first actual member+B Swift qualification failed during compilation after
198.115 seconds. The child exited naturally with status 1, was reaped, and its
process group was absent. Its postflight source recheck passed. The repeated
diagnostics contain exactly two unique source errors: calls to actor-isolated
`expireMemberNegotiation` and `finishMemberRegistrationWait` from timer tasks
without `await`. No Swift fixture completed in that attempt.

`actor-await.patch` adds only `await` to those two calls. The existing cancellation
checks, nonce/wait UUID checks, actor-local state transitions and original
absolute deadlines are unchanged. Both full original source files are retained
under `originals/`; corrected bytes are under `proposed/`. Frozen member
`4ae431c6`, B `69189730`, wrapper `9a33d47e`, the failed logs and its 13,821-file
candidate source inventory remain immutable. `failure-inputs.json` pins the
actual original preparation, source maps, raw output and terminal receipt.

To retain completed dependency compilation and absolute Swift build paths,
the grant-only `prepare_retry.py --apply` updates just the two private workspace
source files. It does not clone a tree, move a cache, alter MAIN, or modify any
old preparation/source/diagnostic receipt. It first verifies the complete old
private and MAIN source/dependency inventories, both preimages, all product and
wrapper freezes, binder/context pins, and the terminal failed child receipt.
It records the originals and stages exact replacements before applying them.
The complete final inventory must equal the original candidate with only those
two substitutions. Any partial preparation is retained and cannot be used by
the retry runner without its successful final receipt.

The corrected receipt and inventory live in the new create-only directory
`coordinator-native-pair-swift-build-1-20260916/actor-await-correction-1`.
The old workspace plus the two retained preimages reconstructs the failed
source exactly; its original inventory is not rewritten. Old wrapper `9a33`
will intentionally reject that now-corrected workspace. This new runner checks
the correction manifest and both inventories before/after every child, and
continues rechecking all failed evidence unchanged.

The source inventory, owned-process, check-process and Swift result-validation
helpers are byte-exact from wrapper `9a33`. The full existing filter, two required
B methods, member/legacy/CLI cases, jobs2, 900-second child bound, 4 MiB diagnostics
and 512 MiB process-file ceiling are unchanged. A matching successful test
receipt remains mandatory before the actual `darkbloom` product build.

After root review and a compiler/preparation grant, run sequentially:

```sh
cd /Users/developer/DarkbloomDev/cluster-research/cluster-member-actor-await-correction-20260916
/usr/bin/python3 -B prepare_retry.py --apply
/usr/bin/python3 -B run.py --phase swift-tests --prepared /Users/developer/DarkbloomDev/cluster-research/coordinator-native-pair-swift-build-1-20260916/actor-await-correction-1 --attempt 2
/usr/bin/python3 -B run.py --phase swift-build --prepared /Users/developer/DarkbloomDev/cluster-research/coordinator-native-pair-swift-build-1-20260916/actor-await-correction-1 --attempt 2
```

No retry preparation, workspace mutation, compiler, Swift fixture, native model,
or remote operation has run for this source correction. Source validation only
checks Python syntax, exact two-line inverse, unchanged inherited helpers, and
the pinned original diagnostics/preimages. Provider native-grant invocation and
encrypted RDMA remain outside this qualification.
