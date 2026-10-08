# Prospective phase sidecar self-check

`checkQwenPrefillPhaseOutput() throws -> QwenPrefillPhaseOutputCheckReceipt`
is a Foundation/Darwin-only fixture entry. It creates one exclusive temporary
directory, touches only files inside that directory, and removes the fixture
directory on return. `main.swift` is a standalone entry; it must not be copied
into the inference executable alongside that executable's own `Main`.

Root may compile these three files together with:

- `QwenPrefillPhaseTypes.swift` and `QwenPrefillPhaseRecorder.swift` from the
  frozen recorder draft;
- `QwenPrefillPhaseFile.swift` and `QwenPrefillPhaseCapture.swift` from the
  sidecar draft.

Alternatively, integrate just the two check-helper files and emit the returned
receipt from the existing adapter check. No MLX, model, network, child process,
or filesystem model path is involved. The code was drafted and source-reviewed
only; root owns compilation and execution.

The twenty logical cases cover exact JSON roundtrip and mode600, preflight
without creation, existing file/directory/symlink refusal, a broken symlink,
missing parent/non-file URL, final512KiB rejection before create, disabled
capture, successful publication after outer return, missing/unsealed/failed
recorder, duplicate owner/publication, a destination created after preflight,
and simulated failed/cancelled/late-native-error outer paths. Invalid operations
must poison retained recorder access; a duplicate publication preserves the
already successful file.

Some capture tests observe the production monotonic clock once; they assert no
duration or scheduling threshold. The direct file fixture uses an explicitly
labelled injected clock. The self-check manually seals synthetic owners, so it
does not prove real request retirement, GPU overlap, or model release.

File-IO failure after exclusive creation may leave a partial new sidecar, as
the production helper documents. The absence assertions concern rejected
ownership/cancelled execution and refusal before creation; they do not promise
transactional file deletion after every possible IO failure.
