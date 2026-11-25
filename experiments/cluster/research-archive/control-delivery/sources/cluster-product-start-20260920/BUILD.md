# Root-owned composition and qualification

No commands below have executed. Do not run during another compiler or physical
window. These commands target the disposable qualified private workspace, never
MAIN. Final product qualification also requires the separate incoming-master
composition; this is the exact known-base test plan.

Working directory: `cluster-research/cluster-product-start-20260920`.

1. `python3 -B check_sources.py` (source only, at most 30 seconds).
2. After root review/grant: `python3 -B Build/run.py prepare` (outer bound 180
   seconds; owned preparation child 120 seconds). It requires the complete
   original 13,859-entry inventory, preserves the exact prior CLI by APFS clone,
   saves every replaced source, then applies the explicit 30-file union. Full
   after-inventory must equal the prospective 13,875-entry map. It never clones
   the build cache or accepts newly discovered dependencies. Partial failures
   remain retained; there is no automatic rollback or retry.
3. `python3 -B Build/run.py tests` (outer 960 seconds, actual child 900, jobs 2).
   It reuses the original matching `helper-2`, whose five shared modules and
   fixture source are unchanged. Actual helper artifacts are rehashed at this
   phase; no helper or native runtime is rebuilt. New owned-child evidence goes
   to this package's fresh `Build/qualification-1/tests/owned-native-evidence`.
   Exact Swift filter and 175 completion labels are in `Build/test-coverage.json`.
   Root must inspect actual discovery/output if a mismatch occurs, preserving
   the failed attempt; do not weaken counts or infer skipped methods passed.
4. Only after those actual checks pass: `python3 -B Build/run.py build` (outer
   960 seconds, child 900, jobs 2), matching `darkbloom` product only. It records
   the real CLI hash and size without running it.

Use the root's existing owned-command launcher for the outer bounds. Each phase
uses the byte-exact prior `check_process.py`/`owned_process.py` internally and
writes fresh logs/exit, reap, group-absence and source/dependency receipts. No
existing output is overwritten. Every build command uses
`--disable-automatic-resolution --disable-build-manifest-caching`; unexpected
source/dependency changes refuse. There are no hardware/TLS credentials or
signing inputs in this package and no environment bypass flags are enabled.

The base has private hardware/TLS experiment code compiled conditionally. This
plan enables no such flags; real product startup uses its normal signer and
trust path. Local HTTP fixture loopback and the existing model-free owner
children are the only intended test network/process activity. No remote host,
model load, Metal evaluation, physical request or public service deployment is
authorized by these commands.
