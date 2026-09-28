# Cluster diagnostics checks

Run `bash provider-swift/Tests/ClusterDiagnosticsChecks/run.sh` from the checkout.
The runner compiles the actual Foundation-only Protocol, Bootstrap, Process,
Remote and Installed sources with Swift 6 warnings as errors. It reuses the
existing installed-session contract values and fabricated metadata child.

Checks cover:

- Leader and follower metadata validation with complete file/mode comparison
  before and after; no matrix publication or model payload exists.
- Expired validation and an unpinned tokenizer fallback refusal without writes.
- Canonical status, fresh nonce and saved identity binding; wrong auth posture,
  schedule, membership, counts, unknown/duplicate fields and integer syntax refuse.
- Loopback, wildcard and an explicitly fabricated assigned local address;
  arbitrary remote/DNS/URL-disagreement/credential-injection cases refuse.
- A held empty device gate remains only an empty-journal observation; a nonempty
  journal remains unproven ownership and its contents are unchanged.

No GPU/model, SSH, remote network or physical collective runs. The small metadata
child is CPU-only. Actual HTTP authentication/route/client tests and CLI parsing
tests live in `ProviderCoreTests/Server/ClusterStatusHTTPTests.swift` and
`DarkbloomCLITests/ClusterDiagnosticsCommandTests.swift` for the full Provider test
suite. These are separate from this source closure.

Temporary binaries and data live under the checkout, avoiding symlinked system
temporary directories rejected by the real file policy, and are removed on exit.
