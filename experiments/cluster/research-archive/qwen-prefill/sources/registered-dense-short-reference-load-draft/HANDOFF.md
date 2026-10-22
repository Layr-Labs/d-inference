# Short full-reference loading support

2026-09-14. Outtree source proposal; Swift compilation, live resource admission,
private-gate behavior and native materialization have not been executed here.

This increment loads one exact registered 9B or 27B full model, then returns CPU
loading evidence after releasing the model and verified file owner. It adds no
CLI, baseline recording, request state, embedding arithmetic, forward or parity
claim. The existing selected-stage entry and its CPU-only return stay unchanged.

`QwenDenseShortReferenceAdmission.admit` accepts an existing exact constructor
metadata admission, a fresh request UUID and captured raw prompt/teacher data with
SHA-256 pins. Both inputs are bounded to 4 KiB and scanned as strict integer JSON.
The actual recorded request is fixed at three prompt IDs, chunk two, one teacher,
two output observations and capacity five; commits are 2/3/4. This is metadata,
not a permit. A future CLI must use bounded regular-file reads before this API.

`runQwenDenseShortReferenceLoadSupport(directory:admission:check:)` owns the single
checkpoint verification, model construction, actual observed descriptor admission
and private gate. Its result contains no model, array, open file or continuation.
The caller still supplies a deadline check and independent process fencing; this
internal support adds neither an alarm nor a process supervisor or output writer.

The gate rebuilds `.fullReference` storage independently of `.stage0`, `.stage1`
and `.sequentialPair`. It uses the companion short ledger's Q, never the long 8K
state fields. R is the sum of remaining individually bounded full-model tensors;
H conservatively stays at the full inventory's largest host tensor until all
reads are consumed, then becomes zero. Actual free must meet
`max(6 GiB, R + 2H + Q + 4 GiB)`. The unchanged current allocator limit must cover
`current active + cache + R + H + Q + 2 GiB`. Absolute swap is zero; existing
pressure, freshness, counter and device buffer checks apply. Reclaimable bytes
are diagnostic. Q and headroom are operational allowances, not a peak proof.

`runtime.patch` adds five new native files and replaces only
`VerifiedQwenDiagnosticLoading.swift`. The legacy preflight/caps remain exact.
Its extracted materializer tail preserves every read/sanitize/cast/eval/update/
freeze/layout/receipt operation; only three error checks, three storage field
names and the default-nil pre-read hook change. The shared topology validator
changes access only. The new optional callback borrows its check within
`withoutActuallyEscaping`; partial failure discards the private model and keeps
native-primary/cleanup errors. No checksum owner is reopened by path.

`fixture-source-list.json` lists 38 pinned Foundation inputs and the existing
shared retained metadata. Compile those exact paths with `xcrun swiftc
-warnings-as-errors`; execute with the listed `stdin` file. The two new fixture
files are `ShortReferenceLoadCheck.swift` and `ShortReferenceLoadCheckMain.swift`.
Expected results are 20 accepted / 98 rejected predicates. Raw-byte/history
separation, fresh UUID, full-role/source binding, ordered descriptors, per-weight
bounds and one-byte resource limits are checked with invented observations.
These do not test the private gate, production payload ordering, partial loading
or cleanup under native failure. No new fixture data is duplicated.

`check_source.py` passed its exact source/patch/dependency checks and nine rejected
source mutations. Read-only patch applicability passed. Arithmetic's five short
ledger files must be integrated from their separately frozen package; the runtime
and fixture lists bind their current exact bytes. The concise parity contract is
frozen separately in `registered-dense-short-parity-plan-draft`; later forward
continuation and numerical qualification remain separate work.
