# Resident physical cut4/28 derivative

This diagnostic shifts four more layers from the24GB rank to the48GB rank after
the cut8 attempt crossed the unchanged6GiB actual-free guard during its first
request. It retains the same8192 input,512 chunk,serial policy,one output,
one warmup and three measured requests; it is not a selected performance plan.

The only runtime delta from the pinned cut8 launcher is SELECTED_CUT=4 plus
admission of4 in the existing independently checked metadata recipe. Native
Plan selection already accepts4. All transport, resources, full reference,
numerical comparison, ownership and cleanup bodies remain byte-identical.
Metadata requires118/809 tensors,1058851136/3979190464 logical active bytes,
and9/63 state components totaling the same927 tensors and72 components.
Loaded tensor bytes do not predict peak free memory or establish execution.

The existing31 CPU tests run with the exact cut4 metadata and complete-state
expectations; the historical cut12 recipe regression remains unchanged.
The retained cut8 manifest identifies the source. Source/review/test records
are separate from physical results, which are not yet available at preparation.

Run: python3 -B run_physical.py --config ABSOLUTE_PLAN --output NEW_OUTPUT
The root supplies exact existing d904 native/package identities in the plan.
