# Explicit immutable bundle reference for private constructor probes

Use `run_dense_constructor_probe_v2.py` with the same required arguments as the
frozen driver. Add both `--reuse-bundle PATH` and
`--expected-bundle-manifest-sha256 SHA` to avoid another bundle copy. Neither
flag is active by default; the existing snapshot branch and base receipt shape
remain unchanged when omitted. The original driver and failed run are retained.

The reviewed existing reference is:

```sh
python3 /Users/developer/DarkbloomDev/cluster-research/dense-constructor-bundle-reuse-draft/run_dense_constructor_probe_v2.py \
  --profile registered_qwen38_27b \
  --expected-native-sha256 8574bb893e147c554880faf0e2e7f501c692a6a1f8812db7772cc3d782b7d946 \
  --output /Users/developer/DarkbloomDev/cluster-research/runs/dense-constructor-27b-nocache-reuse-20260914 \
  --reuse-bundle /Users/developer/DarkbloomDev/cluster-research/runs/dense-constructor-27b-nocache-20260914/bundle \
  --expected-bundle-manifest-sha256 f57b7bfd99430f3bcdbbd425b7f5d810ebad41f4ee2f89ae710f6760113ceb55
```

Root owns execution. This package has not run that command, the native binary,
memory samplers, a model or any checkpoint IO. The reference pin is taken from
the original refused receipt, whose SHA and native identity are retained in
`origin-pins.json`. Refusal remains refusal; bundle availability creates no
native or numerical qualification.

`owned_bundle_reference.py` is the only new reusable helper. Its
`create_reference(source,destination,manifestPin,nativePin,archivedRuntime,artifacts)`
validates an explicitly selected source and creates only a symlink at the new
output's `bundle` path. `check_reference(destination,record,archivedRuntime,artifacts)`
repeats validation. Pass the freshly archived runtime directory and its pinned
`artifacts` module, as the constructor driver does. The readiness driver may use
these exact APIs without changing global runtime helpers.

Validation requires an owned resolved directory, owned nonsymlink regular files
with **no write bits, including owner write**, directories not writable by other
users, a closed bounded manifest and an exact file/directory set. The manifest,
every recorded file and executable are hashed; the two bundled Python runtime
files must match the fresh runtime archive. Requested and destination realpaths
are checked before launch and after the run. The original archive verifier still
checks all current/saved sources, dependencies, manifest and bundle file hashes.
Owners can change permissions; read-only here is a checked file mode plus byte
identity, not an OS immutable flag or a concurrency-proof filesystem snapshot.

The run keeps fresh output files, source archive, source manifest, process owner,
observations and receipt. Reuse adds `bundleAcquisition=reused_external_reference`,
`bundleCopiedForThisRun=false`, both source paths, manifest/native/runtime pins,
verified file count and the helper pin. No source or bundle copy is falsely
claimed. The old bundle and receipt receive no writes or permission changes.

The 1GiB initial/prelaunch actual-free requirement, pressure/no-new-swap and
sampled RSS screens, AC/no-competing-job checks, native120/parent135-second
timeouts, output bounds, input pins, process-group cancellation/reaping and
numerical-audit separation remain unchanged. Bundle verification still reads
the existing files; reuse removes copying, not hashing or the live memory gate.

Nine temporary invented-bundle tests passed, including wrong pins, writable or
unlisted members, symlinks, runtime mismatch, post-creation byte/link drift and
unpaired flags. No invented file is executed. Source checks cover the preserved
driver bodies and bounds; all native validation remains root-owned.
