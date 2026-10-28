# C256 phase-memory source review

No concrete Swift runtime or measurement-contract blocker found in the reviewed 31eb155a source. No compiler, fixture, model, cache materialization, remote or physical execution was performed. All 85 frozen members (487,688 bytes) match; the source checker passed 15 overlays/3 additions, 21 unchanged core controls, 13 exact fixture/helper copies and 26 Python AST files. This is source evidence, not a native execution result.

The three new files own scalar recording, existing-check sampling and bounded encoding. The 12 replacement deltas do not change layer/session math, transport or native backend. The existing allocator snapshot was traced through Memory.snapshot -> mlx_get_memory_snapshot -> MetalAllocator::get_memory_snapshot: one mutex-protected active/cache/process-peak read, no stream wait or peak reset. The OS read is the admitted Mach observation bracketed on the same per-process clock; VM categories remain overlapping and are not admission credit. Load counts mean pre-read authorization, not completed tensor reads. The required native-loaded/request-begin/request-retired anchors and strict same-process interval ordering are coherent. No cross-host time subtraction or continuous/per-chunk peak claim is justified.

The private load entry admits only registered 27B cut16/48; ordinary load retains no observer. Host charge covers actual reserved sample/event capacity and output/scratch/metadata, persists through load, request and publication, and is checked against actual request/rank/source identity. The export retains only scalar results/resources, is built after bilateral request-state retirement, publishes after local lifecycle exit and before capacity return, and rejects retained Data or publication failure. Failed runs cannot supply accepted sidecars. Native model/owner cleanup still requires the original external proofs.

C512 maximum-profile Ready remains deliberately unchanged at its base; C256 actual request reservation is checked separately, including the controller's summed ACK reservation and held-until-release observations. C256 lowers the named boundary/state allowance by 10 MiB per rank; any larger workspace improvement must be measured. This is not permission for cut24 or a relaxed loaded gate. Resource refusal must remain a refusal.

The comparison requires a new d717 ordinary P8192/C256/O128 reference with the exact retained prompt, all 128 tokens, 159 frames, frontier8319, clean actual process/resource evidence and a separately pinned root review. C512 outputs cannot seed expectations. Serial and lookahead use fresh distinct epochs with matched request/source/native/reference identities. The final result is token-sequence parity plus diagnostic intervals/samples; full-row/state numerical qualification and product throughput are not claimed.

## Execution requirement accepted by root

Build/owned_process.py emits one PID line before its wait/cleanup try. Direct use on a failing output pipe could bypass cleanup after spawn. Root explicitly requires every Build controller to be launched through the existing owned wrapper with retained regular stdout AND stderr files, matching the current build convention. That is a concrete prerequisite for this review; no new helper rewrite/freeze is required. Existing source/native preimages and all failures remain retained. Do not invoke the bare controllers through a disposable output pipe.

## Shortest qualified next sequence

From resident-generation-phase-memory-draft-20260917, with separately granted root slots and fresh regular outer logs:

1. `python3 -B Build/check_cpu.py 1`: 11 phase + 8 memory + 5 encoding groups, 12 Python methods, actual Foundation malloc/MemoryLayout budget. Stop on failure.
2. `python3 -B Build/prepare.py`: check the existing 3050/8755 source/dependency tree, preserve binary6495 and 12 source preimages/3 absence declarations, overlay to3053/8755 in the same cache. No whole-cache clone or new controller build.
3. `python3 -B Build/build_native.py 1`, then `python3 -B Build/package_native.py 1`, then `python3 -B Build/check_arguments.py 1`. Preserve the exact new binary/resources/snapshots and all actual results.
4. `python3 -B Experiment/prepare_inputs.py --output /Users/developer/DarkbloomDev/cluster-research/resident-generation-phase-memory-draft-20260917/Experiment/inputs-1`; then `python3 -B Experiment/prepare_reference.py --inputs` that directory. Review the generated binding.patch. Its existing d717 resources/native need no rebuild.
5. In a quiet physical slot, the generated `Experiment/reference/run_physical.py copy`, `run`, `collect`; root reviews all eight actual returned files/resource/cleanup proof. The standalone path retains the established root-exclusive gate protocol; it does not gain a new held lease.
6. Use `Experiment/bind_cases.py` with native/cpu attempt1 and the actual reference returned directory, review path and SHA. Review the resulting immutable serial/lookahead bindings. For each case separately: copy both ranks, preflight both, run, collect, validate_run. Then `Experiment/compare_cases.py`. Exact argv/path instructions are retained in ROOT-STEPS.md; no expected output IDs or future receipt hashes are invented here.

Run no candidate after an incomplete reference, resource refusal, sticky journal, missing ACK, unrestored alias or unsettled process. No timeout, resource threshold, compiler job limit or runtime scope change is needed by this review.
