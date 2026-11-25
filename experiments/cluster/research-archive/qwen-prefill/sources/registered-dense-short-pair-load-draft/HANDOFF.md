# Short registered pair loading support

2026-09-14. Source-only outtree proposal. No compiler, model, payload, forward,
private live gate or native cleanup path was executed by the author.

`runQwenDenseShortPairLoadSupport(directory:admission:check:)` reuses the immutable
`QwenDenseShortReferenceAdmission` for the exact raw prompt/teacher/UUID identity.
That shared CPU value means the intended history matches; it does not attest that
a reference ran or passed. The pair budget has its own domain and sequential-pair
storage/short-ledger role. Geometry remains prompt3/chunk2/teacher1/output2,
capacity5 and committed frontiers2/3/4. No new CLI or existing entry changes.

The outer function owns one verified checkpoint and the existing registered
constructor-source preparation. The full metadata constructor is released there.
The pair helper then constructs both compact stages, validates both actual
inventories, and builds their common storage commitment before any payload read.
It derives the two existing stage budgets plus one short pair Q, using actual
per-array allocator bounds and the device's maximum buffer. The gate is private
to this model-owning file; fabricated pure decisions cannot instantiate it.

Both models stay in an explicit `withExtendedLifetime(values)` scope through the
entire pair load. The existing stage materializer runs unchanged in order0/1.
Each exact stage/local tensor entry is checked before reading; failures poison the
whole gate. Stage completion is allowed only after its full active inventory and
the materializer's final freeze/layout/file checks. Active tensors are evaluated
individually. Inert placeholders may remain lazy, so their allocation allowances
stay in pending R even after both stages complete. No eval(model) is added.

At each observation, R is remaining active allocation bounds plus both inert
allowances. Stage0's loaded active allocation is charged through current native
active/cache while stage1 loads. H is the full pair's largest host-tensor allowance
while any active read remains, then zero. Q is the separate short pair ledger's
operational forward reserve, including the future retained CPU baseline evidence.
Actual free must meet `max(6 GiB, R + 2H + Q + 4 GiB)`; the unchanged current
allocator limit must cover `active + cache + R + H + Q + 2 GiB`. Absolute swap must
be zero; existing pressure/freshness/counter checks apply. Reclaimable bytes remain
diagnostic. These are operational allowances, not a proven whole-process peak.

The returned report retains CPU loading receipts, budgets and observations only.
Weak model/file-owner checks, stream cleanup and cache clearing precede success.
Native-primary and cleanup errors remain distinct. The caller must still provide
its deadline and independent process fencing; this support emits no bytes and
creates no supervisor. It claims neither baseline execution nor numerical parity,
physical inert residency, provider qualification, throughput or hardware fit.
A future recorder/comparator continuation must remain inside the private model
scope; no public arbitrary closure or model handout is introduced here.

`runtime.patch` adds five new files only. `integration-map.json` also maps two new
standalone fixtures to `Tests/ShortPairLoading`. `fixture-source-list.json` lists
39 exact Foundation inputs and the existing shared metadata, with no duplicate
fixture data. Compile those paths with Swift6 warnings-as-errors and run using the
listed stdin: prospective checks are24 accepted/82 rejected. The fixtures use real
metadata/budget types with invented allocations/resources. They cover complete
source ownership/F32 preservation, stage order, inert retention, stage0 resident
charge, per-role/history refusal, one-byte resource bounds and pair-sum overflow.
They do not execute the private gate or independently test actual model retention,
payload ordering, partial loading or cleanup. Those remain native qualification.

Source checks and nine source mutation refusals passed; the additive runtime patch
passed read-only applicability. The resolved pre-freeze inert-reserve finding is
recorded in `INERT_RESERVE_REVIEW.md`. Compilation/fixture execution remain root
owned. No existing selected-stage/full-reference/long/transport code is modified.
