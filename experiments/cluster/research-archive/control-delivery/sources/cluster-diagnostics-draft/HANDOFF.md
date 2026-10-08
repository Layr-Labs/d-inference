# Cluster status and doctor

Private proposal only. No main repository edits, installed model access, native
model execution, SSH or network configuration changes were performed. Root owns
promotion and the full Provider/CLI build.

`cluster status` separates saved canonical configuration/capability pins from an
instant local leader sample. `cluster doctor` additionally runs the shared
read-only installed metadata validator, including the fixed bounded
`--describe-runtime` CPU child, for either leader or follower. It does not publish
a matrix, acquire a lease, contact a peer or perform inference/recovery.

The optional `GET /v1/cluster/status` route exists only on the installed distributed
host. It remains inside the unchanged local authentication stack; explicit
`--no-auth` is supported and reported as unauthenticated. The client uses a fresh
canonical UUID nonce, a three-second response deadline, a 16 KiB byte cap,
canonical closed JSON and exact saved binding comparison. Responses are
`Cache-Control: no-store`. Redirects, proxies, cookies and credential storage are
disabled for the status connection. No raw error/credential/path/prompt/token
values enter the response.

Discovery is locator input only: its PID/time do not establish readiness. The
client reconstructs the URL from validated host/port/base-URL agreement and
accepts loopback or numeric addresses currently assigned to this Mac through
`getifaddrs`; wildcards map to loopback. No DNS or arbitrary remote URL receives
the stored bearer. Scoped IPv6 zone identifiers and arbitrary local hostnames
other than `localhost` remain unobserved; numeric IPv4/IPv6 are supported.

Session observations come from retained actual Pair/Endpoint state. A membership
epoch and observed schedule are retained only after bilateral loaded readiness
passes existing identity/profile/Plan checks. Each peer exposes current native
readiness/capacity and separately observed native cleanup, owner release ACK and
real owner termination. Remaining lifetime is the leader's already-clamped local
duration; remote uptime is never compared with a local clock. A sample is not an
admission or a guarantee that a later request fits.

When teardown removes discovery/listener, status cannot observe that host's
quarantine over HTTP. A nonempty canonical device journal is then explicitly
unproven ownership, not an orphan claim. An empty/absent journal does not prove a
free device. Journal observation performs no lock, write, truncation or recovery.

The validator is the existing pre-publication preparation prefix, with the
existing trust/template revalidation factored into it. Startup retains matrix
publication and validation; unpinned fallback templates now refuse before that
publication as well. No resource/capacity policy or native admission changed.

## Validation

- `qualification-2`: actual Foundation source closure compiled with Swift 6
  warnings as errors and passed in 12.328 seconds, empty stderr. All recorded
  source pins remained unchanged. Leader/follower metadata checks compare the
  complete fixture tree before/after; refusal cases cover expired metadata and
  unpinned templates. Closed status/discovery/journal checks passed.
- `qualification-1` is retained: two deprecated `String(cString:)` calls failed
  warnings-as-errors. Their replacement decodes the same null-terminated bytes;
  no behavior correction or result relabeling was made.
- HTTP/CLI tests are staged, not executed: three real-loopback host/client tests
  in `ClusterStatusHTTPTests.swift`, plus one parser test. They require root's
  full Provider build. The CLI-facing report orchestration and optional provider
  reference reader are outside the direct fixture closure and await that build.
- The installed-session runner gains the two value/codec files required by the
  new session observation API. Its existing lifecycle tests are unchanged; a
  post-promotion runner pass remains appropriate.
- Both shell runners pass syntax checks; the complete patch read-only applies
  against its captured main baselines. Documentation checks target the two
  changed reference pages in a private source overlay.

## Integration

`integration.json` lists all source/base hashes and modes; `integration.patch`
contains the corresponding changes. No Package manifest change is needed.
Suggested root checks after promotion:

```sh
bash provider-swift/Tests/ClusterDiagnosticsChecks/run.sh
bash provider-swift/Tests/ClusterInstalledSessionChecks/run.sh
cd provider-swift
swift test --jobs 2 --filter 'clusterStatus|clusterDiagnosticsParse'
```

No new physical doctor or recovery path is claimed. Actual peer/collective checks
remain explicitly not run by doctor; a live leader report is identified as
retained loaded-cohort evidence rather than a newly executed physical probe.

Independent bounded source review: `independent-source-review.json`, SHA-256 `53dc3f3740f9833ad697ef9a7592358f7af3f3da51b85b36ee8dd525c2c97546`. It covers route/auth/host/discovery and read-only metadata/journal seams; it explicitly excludes an independent CLI/report/ref-reader pass and all reviewer execution. Final reviewed runtime bytes are unchanged.
