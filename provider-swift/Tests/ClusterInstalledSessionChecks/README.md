# Installed-session control checks

Run from a writable checkout on macOS with the Swift toolchain installed:

```sh
./provider-swift/Tests/ClusterInstalledSessionChecks/run.sh
```

The runner directly compiles the current Protocol, Bootstrap, Process, Remote, configuration and installed-session sources with Swift 6 warnings-as-errors. It reuses the existing `MLXLMCommonContractValues.swift` value stubs and `FakeClusterWorker.swift` child. It does not run SwiftPM or link the native MLX runtime. Temporary binaries and fabricated metadata live in a private directory under `provider-swift`, removed on exit. A checkout-local directory avoids weakening the real no-symlink installed-file policy to accommodate temporary-directory aliases.

The checks exercise public model/manifest/tokenizer joins and bounded metadata-command output and deadlines. They then check three installed-path rules:

- The installed build starts its ranks with the runtime's own bootstrap, passes none of the owner-authenticated arguments, and reports `nativeBootstrap: directNative` with `nativeBootstrapOwnerAuthenticated: false`. Supplying an attachment to that selection is refused.
- The plan sets `JACCL_PROGRESS_TIMEOUT_MS`, and a pinned worker whose bytes do not carry the collective progress guard is refused by the validation the leader, the owner and `cluster doctor` share. The stand-in metadata producer is built twice, with and without the names the validation looks for.
- The owner refuses while the ordinary provider's instance lock is held, except by the process that launched it or by a `--cluster-member` process.

Four more rules cover what the saved setup selects:

- Generation mode. A setup that names none starts its workers with the command line it always had and keeps its saved bytes. A named mode reaches both ranks as `--generation-mode` only when the pinned capability record advertises it; one that is not advertised is refused when the setup is read, naming the mode and the worker. The status binding shows the selected mode and what each worker's record advertises.
- Time budgets. Startup, first-token, admission and shutdown waits come from the selected registered model's row. The 9B's row is pinned to the figures the path has always used, and the mode does not change it.
- Pair serving of the registered 27B is withheld. Saving such a setup works; preparing it is refused with the policy sentence, with or without a named mode, and its budgets are reachable only behind that refusal.
- A worker description this build cannot read (a mode or a field from a newer worker) is explained as a mixed install, not as a difference.

Seven actual local owner/stand-in lifecycle scenarios follow:

- A phase-split setup whose stand-in rank 0 publishes tokens in relayed batches of 1, 2, 4 and 8 with a pause before each, and answers a client stop only after a further pause: the published tokens are exactly the accepted ones, the finish is clean, the session stays ready and takes another request.

- Clean drain retains the active request until explicit resource release, then requires native cleanup, owner release acknowledgements and natural owner exits.
- The sixteenth active request retains readiness, while further admission is refused after quota exhaustion.
- A second-owner construction refusal preserves ownership and cleanup of the first launched endpoint.
- A missing release acknowledgement prevents rotation despite native cleanup.
- A nonzero owner exit prevents rotation despite a release acknowledgement.
- Fixed lifetime expiry removes readiness and refuses admission; elapsed time never replaces cleanup proof.

The command protocol, filesystem gates and subprocess supervision are real; the metadata producer and model workers are fabricated CPU children. Fixtures contain no weights or usable credentials. The absent fake payload confirms that metadata preflight does not read weights. These checks do not qualify native inference, real SSH authentication, a two-host deployment, the HTTP server, or the full Provider/CLI build. The test executable has an outer alarm to bound a broken regression.
