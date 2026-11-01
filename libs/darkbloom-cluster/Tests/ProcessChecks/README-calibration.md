# Calibration process CPU gate

The default `Tests/ProcessChecks/run.sh` lane also runs the full
`ClusterCalibrationProcessTests` Swift Testing suite before aggregate success.
`--compile-only` retains its existing behavior and does not claim test execution.
This gate requires the reviewed native-frontier tests (at least39 invocations).
An older source composition fails preflight rather than silently omitting them.

Standalone, from `libs/darkbloom-cluster`:

```sh
python3 -B Tests/ProcessChecks/run-calibration-tests.py --output /tmp/darkbloom-calibration-review-NEW
```

Omit `--output` to create a unique retained0700 temporary directory. Explicit
output must not exist; its parent must exist. No administrator access is needed.
Compile and test bounds default to180/120 seconds; each may be set within1...600
using `--compile-timeout` and `--test-timeout`. Swift compiles use two jobs.
There is no test-filter override. No model, MLX/Runtime dependency, peer or live
provider state is used; bootstrap tests use only task-private local IPC.

Every run enumerates and hashes the current five CPU control/security/bootstrap
modules plus actual `CalibrationFixture.swift`, `ClusterCalibrationProcessTests.swift`,
this runner and the reviewed `Tests/SecurityChecks/owned_process.py` controller.
It snapshots those exact current Swift files into a new dependency-free package,
builds the fixture/tests, discovers the actual bin path and hashes actual
executables/libraries. It checks source sets/bytes after stages, checks binaries
and wrapper artifacts after tests, and retains all command exits, durations,
stdout/stderr and cleanup receipts. No stored evidence-directory source path or
stale frozen import is a product dependency. No fixture implementation is copied
into the runner; fixture bytes are copied from canonical source each run.

The gate requires every declared method and scalar argument case to finish with
the expected passing count, a nonzero Swift Testing aggregate and zero skips.
Conditional case skips, incomplete cases, failed or nonzero-exit controllers,
source changes, unresolved ownership and emergency fixture cleanup all fail.
Unsupported Swift Testing attributes or changed console formats fail closed and
need an updated reviewed parser. The minimum39 count allows future test growth
but refuses deletion back to the historical25-case composition.

Each compiler/test controller uses the existing SecurityChecks owned-process
helper. Fixture executable selection points to a same-PID exec wrapper: it
registers the process UID and exact libproc birth timestamp before `exec` of the
actual Swift fixture. The supervisor still observes the direct fixture PID and
actual exit, with no relay process. On interruption/timeout, controller-group
cleanup is supplemented by exact born-in-this-run fixture identity checks;
reused PIDs are not signal authority. No broad process search or kill occurs.
Any surviving fixture causes failure even after emergency cleanup succeeds.
SIGKILL/power loss cannot run Python cleanup; retained ownership records are
available for explicit inspection, not automatic raw-PID replay.

`checks.json` is the aggregate receipt; `source-snapshot.json`,
`package-snapshot.json`, `binaries.json`, `expected-tests.json`, per-command JSON
and logs, wrapper identities and `fixture-processes/` provide the evidence.
Failures preserve actual aggregate/failure/skip observations without guessing
unreported failed-case counts. Receipts are retained on success and failure and
are outside the existing run.sh build directory's removal trap. Only remove an
exact task-owned output after checking terminal controller/fixture ownership.

Before Swift qualification, run the model-free Python guard tests:

```sh
python3 -B Tests/ProcessChecks/test_run_calibration_tests.py
```

The pinned6KiB parent transport log additionally replays the actual Swift6.3
optional `in N suite(s)` aggregate format; provenance is in Fixtures/.
Those parser/identity simulations do not replace actual CPU qualification.
Independent review plus source-matched build and all39 Swift invocations with
zero skips are required, followed by default run.sh qualification. No Python or
Swift pass is claimed by preparing these files.
