# Machine runtime ownership

This small macOS package has no MLX or sandbox runtime dependencies. The actual
inference serving lifetimes hold shared `flock` leases; a sandbox daemon holds
an exclusive lease until every VM and owned child process is cleaned up.

The authority is `/Library/Application Support/Darkbloom/runtime/ownership.lock`.
An operator provisions its immutable namespace once: all ancestors and the
authority directory are root-owned, without group/other write access or extended
ACLs. The directory can be root:`darkbloom_runtime` mode 0750. The empty, regular,
single-link lock file must be root:`darkbloom_runtime` mode 0660. The dedicated
non-root sandbox broker and provider service identities join that group.

No method creates, truncates, replaces, chmods, or deletes the permanent
`ownership.lock` inode. Installer/upgrade code must preserve it. A lease's
`validate()` method detects a changed path or inode while it is held. Unexpected
permissions, links, identities or I/O failures are errors, not free capacity.

`HostRuntimeAuthority.system.acquireInferenceIfInstalled()` returns nil only
when the authority directory has never been provisioned. Existing installations
therefore keep their inference behavior. Once the directory exists, a missing
or insecure lock fails closed. Sandbox acquisition always requires provisioned
authority. Acquisitions are nonblocking; contention reports `occupied`.

Root offline maintenance uses a separate private `maintenance.json` fence in
the authority directory. A root operator with an existing EX lease calls
`beginRootMaintenance` with an operation UUID and the SHA256 of its protected
journal. Publication is durable and exclusive; neither scope destruction nor
process exit removes it. Ordinary inference SH and sandbox EX acquisition check
for this record before and after acquiring the kernel lock. Any present record,
including an empty, malformed or linked one, keeps new work fenced.

`recoverRootMaintenance` requires root credentials and the exact operation and
journal binding before granting EX. It retains and checks the record's descriptor
and identity; changed files, namespaces, modes or content fail closed. A shared
lease cannot begin maintenance, and a live scope cannot clear a replacement
record even if its contents match. The package-only test policy permits only
its own Unix identity and cannot impersonate root on the real authority.

The operator must independently prove device detach, stopped state and any other
cleanup, then durably preserve that evidence in its journal, before calling
`finishAfterVerifiedCleanup`. This library checks the fence and ownership;
it does not perform or infer VM/disk cleanup. Clearing the record retains EX
until the last lease reference is released. The completed scope cannot be reused.
This global fence also needs the sandbox's per-image broker/native fence so a
direct native VM invocation cannot race an interrupted offline mount. That
per-image integration is a separate unfinished gate.

Root provisioning requires a coordinated transition: inference processes that
started before the authority existed cannot retroactively hold a shared lock.
Provision only on a sandbox-only machine, or stop/upgrade/restart the authorized
provider before enabling sandboxes. Creating the lock while an old provider is
running is not evidence that that provider has drained. Never create or replace
this authority as part of an ordinary unprivileged daemon startup.
The maintenance fence also requires all participating runtime binaries to use
the updated library. An older binary that only checks the kernel lock does not
gain durable-maintenance admission merely because the record now exists.

The provider holds its lease through request cancellation, engine shutdown and
model/cache release. Standalone HTTP serving holds a separate lease from start
through `finishShutdown`. Retain the sandbox lease through corresponding guest
cleanup; a capability flag does not release runtime ownership.

Each actual VM owner process must inherit a duplicate of the exclusive lease
through `withInheritedDescriptor` and a child-only `posix_spawn` dup2 action.
Parent descriptors stay close-on-exec. Retaining the shared open file description
in the VM process keeps inference excluded during the broker's crash-to-VM-stop
window. Destruction closes descriptors only; it must never call `LOCK_UN`, which
would release the lock from surviving child duplicates. Child startup must verify
the inherited descriptor against the provisioned authority inode.

```sh
swift test --package-path host-runtime
```

Tests create temporary authorities under a package-internal owner-policy seam.
Separate processes prove shared/exclusive contention and release. The tests do
not install the system authority, stop providers, or mutate existing VMs. An
abrupt-exit test separately proves that the dead process's kernel lock is gone
while the durable record continues to reject both ordinary runtime roles.
