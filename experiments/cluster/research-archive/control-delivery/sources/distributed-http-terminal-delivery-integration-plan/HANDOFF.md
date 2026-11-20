# Private combined HTTP integration and regression

This plan combines the frozen terminal-delivery V1 and wakeup/body-lifetime
correction without changing either package or MAIN. `integration.json` records
the two manifest hashes, final 20-file map, exact command/filter, and dirty MAIN
base hashes. The six replacements match current MAIN; fourteen additions are
absent. All 25 declared source dependencies still match. The combined patch
passed read-only application checking against MAIN.

The final proposed tree contains twelve runtime files and eight test/support
files. There is no Package change. The six MAIN originals, tracked/staged diffs,
status and package/lock files are retained here. Existing unrelated dirty work
must never be reset, stashed, or replaced during eventual promotion.

`prepare-private.py SOURCE OUTPUT` creates a fresh APFS copy of Provider and its
three local package dependencies, including Provider's cached `.build`.
It checks the transitive local Package path closure and source-symlink targets,
then compares every local source/dependency file in the copy before overlaying
exactly the 20 proposed files. Copies contain no symlink back to MAIN's build
cache. Only copied SwiftPM workspace-state path prefixes are relocated. Source
code and Package manifests retain their original bytes. The original workspace
state is retained with the preparation receipt.

`run-provider-tests.py OUTPUT` is the actual build runner. It refuses mismatched
source inventories or overlay pins, uses two compiler jobs, disables automatic
dependency resolution and build-manifest caching, and records stdout/stderr,
exit status, timeout and candidate/MAIN inventories afterward. Its owned Swift
process group has a 20-minute ceiling; a timeout is a failed retained run, never
a passing suite. This runner does not promote sources or launch a native worker.
A copied incremental cache can require recompilation at its new path; any
relocation/build failure is retained before a separately recorded correction.

The single filter includes every new 26-test method, existing Cluster and
Distributed engine/deadline/host/origin/observation/CLI tests, explicit lowercase
host/status cases, FirstContentDeadline, scripted bridge event/error/shutdown
checks, and selected ordinary solo auth/upload/path regressions. It deliberately
omits actual model/kernel benchmarks. The socket cases use bounded loopback TCP
and fabricated owners, not remote hosts or native workers. Tests are not claimed
passed by this plan; only an actual execution receipt may establish that.

The first prepared workspace is
`../distributed-http-terminal-delivery-private-build-1/workspace`.
Its immutable pre-build preparation receipt pins 13,716 copied source/dependency
files before overlay and 13,730 afterward. It verified only the exact 20-file
change and unchanged MAIN. Runtime review is by root plus the separate pending
pipeline source supplement; that review is not a test result.

Root granted this private compiler slot after physical cleanup. MAIN promotion
remains separate and requires final review plus the actual regression outcome.
