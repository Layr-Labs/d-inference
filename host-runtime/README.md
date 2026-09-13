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

No process in this library creates, truncates, replaces, chmods, or deletes the
authority. Installer/upgrade code must preserve the exact lock inode. A lease's
`validate()` method detects a changed path or inode while it is held. Unexpected
permissions, links, identities or I/O failures are errors, not free capacity.

`HostRuntimeAuthority.system.acquireInferenceIfInstalled()` returns nil only
when the authority directory has never been provisioned. Existing installations
therefore keep their inference behavior. Once the directory exists, a missing
or insecure lock fails closed. Sandbox acquisition always requires provisioned
authority. Acquisitions are nonblocking; contention reports `occupied`.

Root provisioning requires a coordinated transition: inference processes that
started before the authority existed cannot retroactively hold a shared lock.
Provision only on a sandbox-only machine, or stop/upgrade/restart the authorized
provider before enabling sandboxes. Creating the lock while an old provider is
running is not evidence that that provider has drained. Never create or replace
this authority as part of an ordinary unprivileged daemon startup.

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
not install the system authority, stop providers, or mutate existing VMs.
