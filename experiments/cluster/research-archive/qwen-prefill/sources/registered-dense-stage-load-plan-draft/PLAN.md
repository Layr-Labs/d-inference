# Next increment: load one exact registered stage, then release it

Source-only proposal, 2026-09-14. No constructor candidate output, checkpoint
payload, compiler, native process or SSH was accessed for this plan. Current
source pins are in `source-pins.json`. Root owns qualification and integration.

Add one closed experimental entry, `qwen-dense-stage-load-check`, supporting the
existing registered 9B and 27B profiles, their default halves, and stage index 0
or 1. Each fresh process loads exactly one stage and returns CPU evidence only.
Root can run the two stages as separate processes. There is no prompt, request
state, full-model weight load, forward, transport, selectable cut or resident
cohort in this increment. No existing inference admission is widened.

The five exact argument pairs are `--mode`, `--model-dir`,
`--registered-dense-profile`, `--stage-index`, and `--timeout-seconds`. Reuse the
constructor entry's strict parsing, raw metadata bounds, arithmetic environment,
alarm and monotonic checks; stage index accepts canonical `0` or `1`, timeout
remains 1...300. No caller byte ceiling, resource Boolean, permit file or reserve
override is accepted. Keep this new parser outside ordinary `Options`.

## Reuse the current source and loading paths

1. Reuse `QwenDenseConstructorAdmission.admit` for the exact raw configuration,
   manifest and default Plan. This remains metadata admission and its existing
   no-materialization fields remain truthful. Construct `VerifiedCheckpoint`
   once under those exact identities and byte limits, before constructors.
2. Reuse `prepareQwenDenseConstructorSource`. It observes the actual sanitizer,
   descriptor shapes and packed classes, admits the complete registered
   inventory, and releases the full lazy model. Its returned requirement/read
   plan remains `.sequentialPair` **metadata**, allowing both compact inventories
   to be checked. Do not relabel this read plan as a stage requirement.
3. Follow the existing loader order: inspect and release the non-owning compact
   constructor; construct the selected compact model. Check both actual
   inventories with `validateObservedQwenDenseStage`, using the returned pair
   requirement/read plan. Reuse the existing full source conservation and
   storage commitment assembly. Do not first inspect/release both stages and
   then construct the selected stage again.
4. Independently derive `.stage0` or `.stage1` from the same profile and Plan.
   Bind a private loading gate to that stage requirement, the rebuilt pair
   requirement, selected inventory/summary, source identity and one owned model.
   The gate is distinct from the metadata objects and cannot be created from
   `QwenDenseResourcePlan.fitsCallerPlanningCeiling`.
5. Immediately before the first payload read, perform the live resource gate
   below. Then reuse the existing materializer, unchanged in its array work:
   descriptor read, sanitizer, optional F16 conversion, eval, stream completion,
   exact independent-buffer checks, update, freeze and complete final layouts.
6. Copy only its existing `QwenLayerStageLoadReceipt` and bounded scalar memory/
   gate observations out of the owner scope. Check weak model and file-owner
   retirement, drain cleanup, check native errors, clear cache, and check the
   deadline before emitting success. Preserve the constructor probe's primary
   versus cleanup error handling. A failed partial load drops the only model
   and never emits a success report.

The pair metadata check and selected loading gate have deliberately different
roles. Passing the pair-bound source read plan into the stage validator with a
stage-bound requirement would correctly fail its fingerprint guard. Instead,
validate both inventories with the original pair metadata, then require the
selected stage metadata to equal the independently derived stage requirement.
This permits one load; it does not authorize a co-resident pair.

## Small production change set

`VerifiedQwenLayerStageLoading.swift` currently lines 44–120 contains the useful
materialization tail. Extract that tail once into a same-file helper. The old
entry retains its current source preparation and caps and delegates with its
existing ErrorBox check. The new registered entry supplies already checked
source/model/inventory/commitment plus its live check. Replace only references
to the enclosing ErrorBox with the supplied check at the same positions.

One optional `beforeTensor` callback, default nil, runs before `tensor.read(.all)`
only for the new loading gate. It checks pressure, swap, deadline and the next
owned ordinal. The nil legacy path adds no sample, clock read, observer or extra
allocation. It changes no eval, sync, sanitizer or update ordering. The existing
post-sync checks can also run the registered live check without an extra sync.

Suggested new files are a closed CLI/entry, the single-stage owner/report, and a
small resource gate with a Darwin observation adapter. The predicate can be pure
for fixtures; only the production adapter that takes its own current OS/native
observations can create the private one-load gate. Do not add a generic loader
framework, provider hook, alternative load receipt or new Plan serializer.

The existing legacy wrapper must keep 6 GiB canonical/512 MiB host/8 GiB manifest
limits. Registered 27B instead verifies its exact 16,320,415,757-byte manifest,
1,847 canonical tensors and 15,132,802,048 canonical bytes. Those larger bounds
are reachable only through the new exact-profile gate.

## Concrete resource policy to review before wiring

Use actual observations, not metadata-only caller reserves. The minimum initial
policy is a fixed loading-only policy in source, with no CLI lowering:

- Before hashing, retain the current independent parent's initial 6 GiB actual
  free screen, pressure 0...2 and absolute zero reported swap. It keeps sampling
  through hashing, loading, release and process reaping, with its own deadline.
- After hashing and constructor validation, and immediately before the first
  read, the native adapter samples Darwin VM counters, pressure and swap itself.
  Missing, malformed, overflowing or unavailable observations reject. Also
  record MLX active/cache bytes and the current allocator memory limit. The
  parent receipt alone is not a current native admission.
- Compute `roundedResident` from the selected actual active inventory using the
  existing allocator footprint bound for each tensor, plus the small inert
  allowance. Compute `largestHost` from that same selected inventory. Both must
  agree with the exact stage requirement. Do not substitute the whole source
  tensor total, an assumed half, or the 8K state/fusion ledger.
- Proposed initial reserve policy: require at least
  `roundedResident + 2 * largestHost + 4 GiB` estimated reclaimable bytes at the
  post-hash gate. Require actual free bytes at least `2 * largestHost + 1 GiB`.
  The second host-sized allowance and 4 GiB reserve are deliberate policy
  headroom, not a measured scratch bound or proof of memory safety. The existing
  allocator limit must also accommodate observed active/cache bytes plus
  `roundedResident + largestHost + 2 GiB`; do not raise that limit to force a pass.
- Use the existing free/inactive/speculative interpretation, with checked
  arithmetic and explicit fields for actual free versus estimated reclaimable.
  Native pressure must remain 0...2 and reported swap exactly zero. Recheck
  before each tensor and at existing settled boundaries. Require the remaining
  materialization bound against the freshly observed reclaimable amount; do not
  demand the full initial amount again after the gate's own tensors are resident.

These are proposed operational screens for the first bounded load, not a
qualified universal threshold. Root should review the constants with the
parallel source-derived memory-floor memo and completed constructor resource
observations before wiring them. The grant must not exist until the real sampler,
fixed policy and external owner are implemented and tested. Failure to meet a
screen produces refusal; no relaxed fallback or silent cache/allocator tuning.

For 27B default halves, exact logical active+inert bytes are 7,566,416,384 for
either selected role: stage 0 is 7,566,395,904 + 20,480; stage 1 is
7,566,406,144 + 10,240. Largest host tensor is 635,699,200 bytes. These source
geometry facts do not measure allocator rounding, OS availability or whole
process peaks. Current source floats are BF16; no F16-to-BF16 expansion is
needed for these pinned profiles. No attention, GDN state, fusion or logits
allocation is reached by this entry.

## Focused checks and first native qualification

Use the existing retained 9B/27B metadata and actual validators for pure cases:
both selected roles; wrong raw profile/Plan; pair-versus-stage replay; wrong
inventory/key/order/dtype/inert binding; source coverage failure; overflow;
missing/stale samples; nonzero swap; pressure above 2; each exact byte boundary;
and second-use/wrong-ordinal refusal. A fake read counter must remain zero for
every pre-read refusal. Model failure after a later read must preserve the
primary error, release its single owner and emit no successful report.

Source extraction checks must establish the old materializer's array sequence
and legacy limits are preserved. Existing short/tiny load fixtures are the
regression route; the registered 9B selected-stage loads provide a native control.
Then root runs fresh registered27B stage 0 and stage 1 processes independently
under the reviewed guard, retaining source/binary/input/parent evidence and each
existing complete load receipt. A metadata oracle checks source/Plan/active/inert
coverage and accounting. It does not independently prove tensor values.

Success means the selected checkpoint tensors were installed, settled and
checked by the pinned producer, followed by model/file release and cache cleanup.
It does not establish numerical parity, forward eligibility, provider/M3 math
qualification, physical transfer, 8K memory fit, TPS or resident stage reuse.
