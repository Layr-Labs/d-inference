# Installed-session control checks

Run from a writable checkout on macOS with the Swift toolchain installed:

```sh
./provider-swift/Tests/ClusterInstalledSessionChecks/run.sh
```

The runner directly compiles the current Protocol, Bootstrap, Process, Remote, configuration and installed-session sources with Swift 6 warnings-as-errors. It reuses the existing `MLXLMCommonContractValues.swift` value stubs and `FakeClusterWorker.swift` child. It does not run SwiftPM or link the native MLX runtime. Temporary binaries and fabricated metadata live in a private directory under `provider-swift`, removed on exit. A checkout-local directory avoids weakening the real no-symlink installed-file policy to accommodate temporary-directory aliases.

The checks exercise public model/manifest/tokenizer joins, bounded metadata-command output and deadlines, then six actual local owner/stand-in lifecycle scenarios:

- Clean drain retains the active request until explicit resource release, then requires native cleanup, owner release acknowledgements and natural owner exits.
- The sixteenth active request retains readiness, while further admission is refused after quota exhaustion.
- A second-owner construction refusal preserves ownership and cleanup of the first launched endpoint.
- A missing release acknowledgement prevents rotation despite native cleanup.
- A nonzero owner exit prevents rotation despite a release acknowledgement.
- Fixed lifetime expiry removes readiness and refuses admission; elapsed time never replaces cleanup proof.

The command protocol, local Unix bootstrap, filesystem gates and subprocess supervision are real; the metadata producer and model workers are fabricated CPU children. Fixtures contain no weights or usable credentials. The absent fake payload confirms that metadata preflight does not read weights. These checks do not qualify native inference, real SSH authentication, a two-host deployment, the HTTP server, or the full Provider/CLI build. The test executable has an outer alarm to bound a broken regression.
