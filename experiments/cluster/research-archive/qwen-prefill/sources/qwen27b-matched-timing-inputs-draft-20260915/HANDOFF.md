# Matched registered 27B timing inputs

This source-only input contract fixes the shared diagnostic 8192-token workload,
chunk512, output128, cut16, empty stops and MTP off. Each cohort has one warmup
and three measured fresh requests. The distributed serial and lookahead paths
reuse the existing model-generic TimingCohort; optimized solo reuses the existing
resident solo loop. Their clock scopes and diagnostic capture differ and are
recorded explicitly in specification.json. These are native request timings,
not external content TTFT. Whole parent elapsed time is not throughput.

The root-provided full-reference pin is1922793a…70305. bind_reference.py requires
that explicit path/hash, verifies the frozen 8K helper and its transitive source
inputs, then runs the unchanged complete reference validator before retaining
its128 selected IDs. It rechecks file identities and creates a fresh output
directory. It has not run here and does not launch a worker or grant capacity.
The prompt remains the exact existing8192-ID workload ee6caf0b…fe997; no9B
expected output is reused. The serial8K correctness comparison has separately
passed under root; its elapsed98.681s is not a timing-cohort measurement.

Both native ancestries retain their own model/resource/math sources. Full-model
solo remains64 layers on48GB; distributed cut16 remains16/48 layers. The
lookahead policy must first pass its prospective full token/row/state comparator;
that separate policy binding is not silently replaced by the serial comparator.
For later fresh-UUID timing,128-ID agreement is only a sequence guard.

The existing lifetime300s, request120s, startup90s and315s parent bound are
retained. Completion of all four requests within those bounds is unproven.
Retain partial and failed requests; emit no aggregate unless all four and actual
cleanup pass. Do not renew an epoch or raise a deadline to obtain an aggregate.
Actual free-memory, allocator, AC, pressure, thermal and zero-swap gates remain
unchanged. Encrypted-RDMA qualification and product/HTTP performance are outside
this contract. Neither materialization, compilation nor model/remote execution
was performed by this preparation.
