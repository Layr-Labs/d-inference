# Pure short-execution runtime binding

`runtime_binding.py` validates the existing Swift
`QwenDenseStageLoadRuntimeObservation` objects from the full baseline and pair
report. It adds no native DTO, runtime observation, model path or executable mode.

```python
from runtime_binding import validate_runtime_pair

identity = validate_runtime_pair(
    full_runtime, pair_runtime, expected_pid,
    allowed_bundle_paths=[launch_bundle_path, resolved_reuse_bundle_path],
)
```

The caller first validates the completed parent and its fresh/reused bundle
schema. Supply one exact root for a fresh snapshot. For reuse, supply the launch
root and, if different, `bundleReference.resolvedPath`. The helper creates the
launch symlink directly to that resolved root. Its `requestedPath` is merely the
input spelling and must not be added automatically. The validator does not check
that supplied roots are aliases; that belongs to the parent/bundle audit.

Paths are historical strings: no file opening, `realpath`, symlink following or
directory enumeration occurs. Roots are one or two unique absolute normalized
POSIX paths, at most 4,096 UTF-8 bytes each. Relative/dot/empty components,
backslashes and control characters are refused. This component covers the flat
command-line bundle created by `runtime/bundle.py`: `mainBundlePath` and any
reported resource path must be allowed roots; the executable must be exactly an
allowed root plus `/cluster-inference`. Different validated aliases may appear
within one record. Full and pair records must then be exactly equal; an alias
switch between records is refused. No `.app/Contents/Resources` scope is inferred.

The 11 required and four optional native fields have strict types. Swift omitted
optionals remain omitted; explicit JSON null is refused. Executable name/path
must appear together and match when present. If both are absent, the returned
`executablePathReported` is false and `executablePathMatchesAllowed` is null;
there is no invented executable-path evidence. The parent layer can require that
evidence for its final qualification. Bundle ID/resource-path omissions are also
supported. The three native false flags must be actual Booleans equal to false.

PID is positive Int32 and equals the supplied parent PID. Device memory and
maximum buffer are positive signed-64-bit values; advisory working set is UInt64
and may be zero. There is no invented ratio between these limits. Architecture
and OS must be bounded nonempty known strings, but no hardware family is inferred
from their spelling. Other text is limited to 1,024 UTF-8 bytes. The detached,
deterministically ordered result encodes to at most 32 KiB as compact UTF-8 JSON.

The result retains `naxAvailability="unknown"`, no hardware attestation, no
runtime-file byte verification, no provider eligibility and no execution
admission. It does not validate the parent, native hashes, metallib selection,
source correlation, arithmetic environment, numerical parity, device capacities
against independent hardware evidence, or resource admission. Those are joins
owned by the enclosing audit; PID/path equality alone is not attestation.

Run the fabricated CPU tests with:

```sh
python3 -B -m unittest -v test_runtime_binding.py
```

The source pins bind the native DTO, fresh bundle constructor, reused-reference
helper and parent call site. No actual candidate records, model files, compiler,
native process or SSH were used to author or test this component.
