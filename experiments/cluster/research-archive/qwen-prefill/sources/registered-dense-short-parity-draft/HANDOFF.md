# Registered short full-to-pair parity entry

2026-09-14. Out-of-tree source proposal. Root owns compilation, integration and
guarded native qualification. This package has not executed a model or read a
candidate result.

`runQwenDenseShortParity(directory:admission:onBaseline:check:)` uses the existing
`QwenDenseShortReferenceAdmission`: exact registered 9B or 27B metadata, default
16/16 or 32/32 Plan, three captured prompt IDs, chunk size two, one teacher ID,
two output rows, state capacity five and committed frontiers 2, 3, 4. The CLI
creates one fresh request UUID and offers no geometry, arithmetic, cut, memory,
repeat or warmup overrides.

The full owner materializes once under its existing actual-descriptor-bound
private gate, finishes the actual baseline representation, and invokes the
unchanged `recordQwenLayerStageBaseline`. It returns CPU evidence only after
request retirement, weak model/file release checks, stream synchronization,
cache clearing and the released OS sample. The baseline is then published.
Publication failure stops the call before pair loading.

The pair owner validates the exact recorded request, raw source identity and
Plan before its first resource/file/native operation. It independently verifies
the checkpoint, constructs both actual inventories and admits the entire pair
weight budget plus short request Q before its first payload read. Both stages
remain retained while the unchanged `compareQwenLayerStageRecordedRequest`
replays the three steps. The existing comparison checks complete state metadata
and digests and compares the two full native vocabulary rows byte for byte.
No numerical tolerance or model operator is added or changed.

Actual free memory remains at least `max(6 GiB, R + 2H + Q + 4 GiB)` and the
existing allocator condition remains `active + cache + R + H + Q + 2 GiB`.
Zero swap, the existing OS/allocator checks and the 8192-observation cap remain
unchanged. Q stays reserved during execution. Both inert allowances remain in R
through pair completion; this proposal does not infer their residency or add
`eval(model)` to the stage materializer. These operational allowances are not a
proof of peak process memory safety. Independent parent fencing is still needed.

The existing loading-only entry signatures, report DTOs and false forward flags
remain unchanged. Their closed `.loadOnly` branches perform no new embedding or
request work and preserve native operation, final memory observation and cleanup
order. The new parity reports have separate namespaces and true enclosing
forward/retirement fields. Nested existing budget/resource decision fields such
as `forwardExecuted=false` describe those pure planning/predicate operations;
resource observations can now be collected during the enclosing forward pass.

The only new arithmetic outside the shared record/replay loops is the existing
real token-zero embedding probe extracted byte-for-byte from the legacy baseline
finishing block. The extraction changes indentation, replaces its two
`error.check()` calls with the supplied checked callback, and passes the original
label explicitly. The legacy caller retains its exact preflight/load prefix.

The closed eight-pair command is:

```
--mode qwen-dense-short-parity-check
--model-dir /absolute/model
--registered-dense-profile registered_qwen35_9b
--tokens-file /absolute/prompt.json
--tokens-sha256 <exact lowercase SHA256>
--teacher-tokens-file /absolute/teacher.json
--teacher-tokens-sha256 <exact lowercase SHA256>
--timeout-seconds 300
```

The other profile is `registered_qwen38_27b`. Timeout is canonical 1...300.
Each raw token file must be regular, unchanged during its bounded descriptor read,
at most 4096 bytes, and match the supplied hash. Existing strict JSON integer
admission is reused. The process alarm and monotonic checks cover setup, both
owners and publication. Each complete JSONL record is at most 32 MiB including
its newline, and the two-record total is at most 64 MiB. Any encoding, deadline
or output error poisons publication. A retained first record is a baseline only;
successful parity requires the second record and a successful outer process.

`check_source.py` checks exact extraction, original byte pins, retained resource
and numerical dependencies, private gate identity, ownership/order invariants,
and rejected source mutations. These are source checks, not execution of private
gates, partial loads, request cleanup or native parity. Root supplies separate
pure CLI/input/output fixture results and later native evidence. No public
Python launcher, transport protocol, long profile or provider eligibility changes.

Root's final 40-source Swift 6 warnings-as-errors fixture passed **19 accepted /
83 rejected**, with empty compiler/runtime stderr and unchanged input pins.
It uses the actual parser, bounded synthetic token files, real retained metadata
admission and fabricated CPU publication values. It does not execute either
private model owner. The initial fixture exposed a swallowed-reentry publication
bug; root added the state guard immediately before writing. The failed first run,
original output source and exact historical fixture pins are preserved. Subsequent
fixtures assert zero writes for reentry, wrong order, encoding and size failures.

`integration-map.json` lists 14 runtime files (five replacements and nine new
files) plus two fixtures under `Tests/ShortParity`. `runtime.patch` contains only
the runtime changes and passes read-only `git apply --check` against the saved
base. `reviews-and-validation.json` binds independent owner/seam reviews and
root's CPU execution. Public runner/documentation support follows separately.
