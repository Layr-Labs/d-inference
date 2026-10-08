# Optimized registered 27B solo build preparation

This isolated build starts only from the actual8952 optimized-solo source/cache
snapshot:3290 source files and9502 dependency files. The frozen9420d783…1c80
adapter replaces four files and adds two, producing3292 source files. The
selected registered27B model uses64 layers, cut16 metadata and48 GatedDelta
layers; prefill/decode warmup requires768/6096 native dispatches. The existing
resident request loop, load/resources, math and MLX build flags remain intact.
No989f worker source or later MAIN source is substituted.

prepare.py first verifies exact ancestor metadata and full source/dependency
inventories, then creates a fresh APFS source/cache clone under one owned60s
child. Source symlinks and generated cache paths are rebased only in the new
tree, old module caches are retained, and original/new source inventories are
verified again. Nothing has been materialized at this freeze.

build_check.py runs the exact qualified release compiler argv with maxjobs2,
macOS26.2 and a900s owned bound, followed by10s Mach-O inspections. Its separate
60s metadata-check mode must return19 accepted/35 rejected with no model/kernel
execution. package_native.py requires both successful matching receipts and
unchanged source/binary/resources, then writes a fresh source manifest and the
existing closed three-file bundle envelope. The original8952 bundle is retained.
All child failures and incomplete outputs remain separate evidence.

The source/AST checks passed, including exact compiler argv and source snapshot
convention. Five fabricated supervisor contract tests passed in0.090s wall
(system Python;0.033s unittest): complete four-request output, wrong warmup
counts, old model inventory, partial/unretired output and unbound native pins.
No actual model/reference/output data was read by those tests. The frozen
six-file native adapter has separate source review1a79231e…0d12f; the build/run
wrapper's independent review is pending and root is the immediate source gate.

run-template retains the existing run_solo/ResourceGate/contract closure.
Only solo_inputs and solo_contract adapt the registered model/Plan, inventory
and48-layer counters. The operational worker_processes helper is separately
bound to the reviewed and physically passed safe26448b0…95356 implementation;
the unsafe olda829 helper is retained only under upstream for provenance.
Fifteen runtime sources have a checked transitive import closure. run-template.patch
and run-template-lineage.json identify every changed boundary.

prepare_run.py accepts an explicit pinned common shared-input file only after
build/check/package. It validates the frozen specification, exact raw prompt
and128 reference IDs, binds actual native/source hashes into the intentionally
unbound template, writes a fresh job/launcher tree and validates the job locally.
It performs no deployment, model read or native launch. The resulting job retains
native300/parent315 seconds, same canonical device exclusion and current guards.
Root must review and create-only deploy the resulting pinned runtime/inputs,
perform authorized purge/preflight, run the existing supervisor and collect
independent process/journal postflight. Final remote package/run pins cannot be
frozen before actual native artifacts exist.

The common timing contract is warm1+measured3, P8192/C512/O128, empty stops and
MTP off. Four requests fitting300s is unproven; preserve failures/partials with
no aggregate. Solo starts its clock before fresh request state, while distributed
TimingCohort starts after reserve. Report those scopes and diagnostic-capture
differences. This is neither external TTFT nor encrypted-RDMA qualification.
