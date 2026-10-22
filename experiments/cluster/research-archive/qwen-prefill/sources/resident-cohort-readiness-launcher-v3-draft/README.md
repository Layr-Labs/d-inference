V3 is a private, separately frozen derivative of the V2 readiness launcher (`f54500b45800ecf56995bc5a8b2665368f465a41508a43d4bf63e87b171c0e96`). V2 and its actual failed mismatch evidence remain unchanged. V3 does not accept or relabel that run.

The companion native patch in `../readiness-complete-before-compare-draft` makes both ranks finish their existing ordered digest exchange before comparing. V3 requires that exact archived exchange SHA `a075b13f8606dcccd9459ba8140559af4d9d696bf9621c1b2d92838f333e210d` and the bytecode-suppressed worker SHA `2dbb639e3e112198f9a15cfeb98b21209657651e2126f6d59d7819202d55f5e3`. Root must compile and supply the resulting new executable pin; no old executable is substituted.

The native CLI, fixed 64 Int32/256-byte message, arithmetic/request/cohort domains and one-line success DTO remain unchanged. V3's parent receipt kind is `private_model_free_cohort_readiness_launcher_v3`, with `mismatch_contract=both_exact_disagreement_exit1_before_parent_deadline`.

For `warmup-mismatch`, either rank may finish first. A sole exit 1 leaves the other rank time to finish within the same parent deadline; it does not authorize cancellation or success. Qualification requires both supervisors naturally exit 1, both are reaped, both stdout files remain empty, and each stderr is exactly the existing loopback warning followed by:

```text
cluster-inference: Resident ranks disagree on ordered requests, warmups, source or policy before stage load
```

The worker forwards its native child status and owns native waitpid. Native semantic exit is source-bound to that unchanged behavior plus the exact diagnostic; the parent independently observes/reaps supervisors, not a second native waitpid. Mismatch remains `native_success=false`. Validation and final stream revalidation are charged to the parent deadline. A peer cancelled by the parent, another exit code, missing/truncated diagnostic, ring error, extra line or post-agreement stdout fails. There is no generic peer-loss allowance.

`match` still requires two complete matching success records, exact warning-only stderr and two zero exits. `missing-peer` still starts only rank 0 and qualifies only the existing parent-deadline startup cancellation with the child observed running when cancellation begins, reaped nonzero afterward, empty stdout and warning-only stderr. An already exited child discovered after a slow observation remains inconclusive. Native timeout30, match/mismatch parent45 and missing-peer parent3 seconds are unchanged.

Source/archive/native/bundle/config pins, initial/prelaunch actual free >=1GiB, pressure<=2, no increase in reported swap, bounded streams, source-bound diagnostics, owned cleanup and independent postflight errors remain. Optional explicit bundle reuse is copied unchanged from V2: both reuse arguments are required together, the exact read-only tree is rechecked independently, and no old cache-mutated bundle is repaired or permitted. Use a fresh bundle containing the new executable and corrected worker, or omit reuse to take a new snapshot.

Root executes on the selected Mac using its owned checkout/release paths:

```text
python3 -B launch_readiness.py
  --runtime <owned-checkout>/experiments/cluster/runtime
  --release <owned-checkout>/experiments/cluster/inference/.build/release
  --expected-native-sha256 <new-complete-before-compare-build-SHA>
  --scenario match|warmup-mismatch|missing-peer
  --output <new-outside-repository-output-directory>
```

All 36 fabricated tests passed: the inherited 25 tests with only mismatch expectations updated, four unchanged reuse wiring tests and seven new strict mismatch cases. New cases cover either completion order, a parent-cancelled peer, another exit code, exact per-role diagnostics, rejected ring output and final validation exceeding the deadline. Process/socket calls are forbidden or replaced with fakes; no new native candidate was accessed.

The native patch's four separate finite schedule tests do not simulate socket teardown. Completed native send permits local release but does not acknowledge peer consumption. Native checks/transport errors or teardown may still prevent both exact semantic exits; the actual V3 cohort must establish the requested result. No new barrier, retry, sleep or permissive diagnosis hides that limit. No model loading, request execution, resident reuse, physical transport or throughput is qualified.
