# Shared owner diagnostic drain promotion

Seven files were promoted to MAIN with guarded preimages and retained backups.
All 174 members of the frozen diagnostic-drain candidate were verified first.
The two runtime files and three new fixture files are byte-exact copies; only
the existing SSH check runner and its README have new integration edits.
The private qualification controller remains outside MAIN.

`promotion.patch` is the exact seven-file delta. `preimages.json`, `originals/`
and `promotion-result.json` retain the before/after evidence. All 52 unrelated
files in the scoped control-module/test inventory remained unchanged. The
entire 37-file shared control source closure now matches the tested candidate,
with no additional MAIN control sources. Existing fixture helpers and the
thirteen SSH plus six retirement cases match their frozen tested sources.
The repository's pre-existing dirty work was preserved; no Git reset, checkout,
stage or commit was performed.

The endpoint retains diagnostics emitted after an authenticated release ACK
through its existing bounded natural-exit grace and final pipe drain. The helper
keeps the 1 MiB capture cap and reports actual diagnostic EOF separately from
native cleanup, authenticated lease release and actual transport termination.
The owner-ended barrier follows reaping, bounded draining and descriptor closure.
No native wire, admission, request deadline, ownership or journal rule changes.

The five added groups cover delayed post-ACK stderr, nonzero owner exit, a hung
post-ACK owner, an independently retained pipe writer and oversized stderr.
The three fixture files are retained unchanged, including their archived baseline
branch; the runner explicitly defines `OWNER_DIAGNOSTIC_DRAIN` to run all five
corrected-path groups. Existing tests remain before these additions.

After root releases the compiler slot, run from the repository root:

```sh
bash libs/darkbloom-cluster/Tests/SSHChecks/run.sh
```

This compiles the actual Protocol, Process, Bootstrap and Remote sources with
Swift 6 warnings as errors and at most two jobs, then runs 13 SSH, 6 retirement
and 5 diagnostic groups with actual local CPU children. It also compiles the
existing configured-owner entry. There is no SSH, remote, MLX, model or GPU run.
No MAIN compilation or test has run during this promotion: root's solo timing
and subsequent native build held the compiler. Upstream baseline reproduction,
the corrected 5+6+13 checks and the portable controller build passed in the
frozen candidate. Those results do not substitute for the pending MAIN run.

Modularity review: `ClusterRemoteWorkerEndpoint` retains process/descriptor
ownership and shutdown ordering; the focused `ClusterOwnerDiagnostics` helper
owns only bounded byte capture and EOF state. Fixture child behavior, owner
behavior and assertions remain separate files and reuse the existing identity
helper. The runner discovers the new shared helper through its existing module
source glob, so no package manifest or dependency change is needed.

Upstream manifest:
`ebccbc7e4f216af0313c0f1ce36711f06dd570dafe92a136ce1a673ca4536615`.
Upstream runtime patch:
`d8bb8ce01b14df3c6b3a2ba3712b2f93b7507209a0dbca1b230799cb6ecb37c2`.
Independent four-file source review:
`750193b50edab803e91ce10aa616a764561f55457100481960646e29f7452415`.
The new repository-runner wiring review is pending separately.
