# Go CI workload benchmark

`../../Scripts/benchmark-sandbox-ci.py` measures real Go compilation and unit
tests for `coordinator/protocol`, `coordinator/sandboxhost`, and
`coordinator/sandboxcontrol`. It includes their actual local dependencies and
an offline vendor tree, builds a probe that exercises the selected packages,
compiles each package's tests, and executes those binaries with their fixtures.
This is separate from the integer-recurrence CPU microbenchmark.

Use the physical Mac hosting an explicitly selected, ready **nonproduction**
sandbox. The runner requires the same OS/architecture on both sides. Record the
VM CPU/RAM allocation and competing host work; the harness does not stop other
processes, modify provider scheduling, create/delete sandboxes, or renew leases.

## Host-only validation

Provide an installed local Go SDK and a populated local Go module cache. The
selected source revision must be a commit containing the sandbox implementation.
Working-tree edits and untracked source files are excluded. Missing cached
dependencies fail preparation; the harness does not download them.

```sh
python3 sandbox-macos/Scripts/benchmark-sandbox-ci.py \
  --host-only --repo /absolute/d-inference --revision COMMIT_SHA \
  --go-sdk /absolute/go-sdk --module-cache /absolute/go/pkg/mod \
  --output /absolute/new/ci-host-evidence --pairs 2 --gomaxprocs 4
```

The result is labelled `host_workload_only`; it provides no VM performance
measurement. `make sandbox-ci-test` runs the Python evidence/bundle tests and
standard-library Go runner race tests, using temporary Go caches. It runs in
`sandbox-test`, the macOS sandbox CI job, and the default validation harness;
those tests never perform paired measurements or contact a VM/API.

## Paired measurement

Set `DARKBLOOM_API_KEY` through the environment. An API URL and explicit
nonproduction confirmation are required; known production coordinator names
are rejected. Do not include real credentials in saved commands or reports.

```sh
python3 sandbox-macos/Scripts/benchmark-sandbox-ci.py \
  --repo /absolute/d-inference --revision COMMIT_SHA \
  --go-sdk /absolute/go-sdk --module-cache /absolute/go/pkg/mod \
  --cli /absolute/darkbloom-sandbox \
  --api-url https://your-nonproduction-coordinator \
  --sandbox SANDBOX_UUID --confirm-nonproduction \
  --output /absolute/new/ci-paired-evidence --pairs 3 --gomaxprocs 4
```

Only an explicitly selected loopback HTTP coordinator can use
`--allow-insecure-localhost`. The sandbox CPU count must cover `GOMAXPROCS`.
The full campaign must fit the existing lease; each inner run defaults to an
840-second maximum, below the 900-second command limit.

## Measurement contract

- A Git archive pins tracked source to one immutable commit. Dependency listing
  runs against a temporary copy; only the selected packages, their real local
  dependencies, required fixtures, and the generated probe enter the bundle.
- Module archives/metadata are copied from the explicitly selected local cache
  into private temporary storage. Vendoring runs offline there. Existing source,
  caches, SDK and user Go configuration are not edited or cleared.
- The exact SDK, source/vendor archive, and portable runner binary are uploaded
  through the consumer CLI. The runner verifies all archive hashes and the
  manifest, rejects archive links/traversal/overwrites, and verifies extracted
  file contents and executable modes before every sample.
- Every run creates a new `GOCACHE`, `GOMODCACHE`, `GOPATH`, home and temporary
  directory. Environment settings include `GOTOOLCHAIN=local`, `CGO_ENABLED=0`,
  `GOPROXY=off`, `GOSUMDB=off`, `GOVCS=*:off`, `GOENV=off`, `GOTELEMETRY=off`, and
  `GOFLAGS=-mod=vendor`. No database URL or API credential reaches the workload.
- Compilation uses `-p 1` and explicit `GOMAXPROCS`, avoiding multiple compiler
  processes multiplying the CPU budget on the larger native host. Both sides
  use `-trimpath -buildvcs=false -ldflags=-buildid=` for comparable artifacts.
- `build_seconds` covers probe compilation and three `go test -c` invocations.
  `test_seconds` covers executing the compiled probe and all three package test
  binaries, captured through `go tool test2json`. Tests use `-test.count=1` and
  run from their package directories. Skipped, missing or failed test cases
  cannot enter a successful measurement.
- SDK/source verification, archive extraction, evidence packing/hashing,
  uploads/downloads, and API delivery are excluded from inner timing. Guest API
  wall time is separately retained. SDK/source verification reads input files;
  **OS page caches are not flushed**. This is a fresh Go build-cache workload,
  not a claim of cold physical storage.
- Paired runs alternate host-first/guest-first order. Summaries require identical
  input manifests, SDK/platform, compiled artifact hashes and passing test case
  counts. Downloaded binaries are independently hashed from retained evidence.

## Evidence and interpretation

The private output directory retains `measurements.json`, source/SDK manifests
and inventories, exact input archives and runner, vendoring/dependency logs,
every CLI result and command ID, compiled artifacts, probe results, raw test JSON,
and per-command timing. Failed samples remain failed and do not produce a
performance summary. Temporary build caches are removed; evidence is retained.
CLI capture is limited to 8 MiB per stream, preparation-tool capture to 32 MiB
per stream, and runner command logs to 32 MiB. Timeouts and overflow retain
partial diagnostics and cannot count as successful samples. Credential masking
also covers escaped JSON values. Extracted SDK/source archives have byte/member
bounds; downloaded evidence is limited to 256 MiB and 128 regular-file members.

The harness leaves its uniquely prefixed directory in the selected sandbox for
inspection. It does not remove other workspace files. Delete the sandbox through
the normal consumer lifecycle when finished.

No release-readiness threshold is inferred from a successful run. Three pairs
are a bounded initial campaign, not a statistically strong tail estimate. Use
enough pairs for the intended claim and preserve raw measurements. Cold boot,
two-VM contention and inference coexistence require separate measurements.
