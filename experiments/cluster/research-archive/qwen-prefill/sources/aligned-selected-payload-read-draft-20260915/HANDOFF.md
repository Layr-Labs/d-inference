# Aligned selected-payload reader

`integration.json` and `runtime.patch` contain 11 Swift files against the frozen payload-cache workspace: eight existing files and three new files. Root applied those exact bytes to the isolated aligned-read build. This package does not modify the main repository or execute a native model.

Selected-stage descriptors request `F_NOCACHE=1` and `F_RDAHEAD=0`. For each selected span, the new reader uses the same verified FD, rounds the source window to 16 KiB, and reads through at most 8 MiB of private anonymous scratch. The scratch maps fd=-1, never the checkpoint file. It requires the actual system page size to be 16 KiB, checks alignment/extent, and unmaps before successful return. The original selected Data buffer and `MLXArray(Data,...)` copy remain. Axis selections and composed tensors still copy only their selected spans.

Every successful read must return the exact requested bytes, except an expected EOF short return that equals the verified remaining file length. Unexpected positive short reads fail; EINTR retries the same aligned pointer/offset/length. Range and rounding arithmetic is bounded before allocation. FD identity is checked around reads. No path is reopened, and no full tensor or model file is mapped.

`sourceLoad.selectedPayloadReadAccounting` is an optional operational extension; all previous semantic load fields and the storage commitment remain unchanged. Its schema is `checkpoint_aligned_selected_read_v1`. It reports selected/requested/returned/padding bytes, total and interrupted pread calls, EOF-short calls, and maximum requested/mapped scratch extents. `returnedReadBytes = selectedBytes + paddingReadBytes`; requested bytes include EINTR attempts and the requested tail beyond EOF. Cache-bypass/read-ahead flags record requests, while `fileCacheAbsenceEstablished` remains false. Accounting travels with read results, so each stage of a sequential pair gets its own totals.

The conservative host scratch allowance remains 8 MiB + 16 KiB (8,404,992 bytes). Actual anonymous mapped extent equals its request and is at most 8 MiB. Selected-stage and short-pair actual-free requirements add the allowance only while payload reads remain. Their 6 GiB minimum, zero-swap checks, MLX allocator requirements and completed-state requirements are unchanged. Ordinary cached/reference/checksum copy code remains the exact previous body; no blanket claim about checksum/metadata cache absence is made.

Completed CPU validation:

- Seven-source Swift 6 warnings-as-errors compile and real-file checks: 9 accepted, 10 rejected; 0.976 s compile, 0.885 s run, empty stderr. Receipt `cpu-v2/execution.json`.
- Selected-stage policy: 32 sources, 21 accepted/122 rejected; 3.853 s compile, 1.784 s run, empty stderr.
- Short-pair policy: 41 sources, 24 accepted/82 rejected; 4.984 s compile, 1.678 s run, empty stderr.
- Independent runtime and policy-fixture source reviews found no remaining blocker. The policy overlays add only the explicit scratch threshold and two new source dependencies; shared retained metadata is referenced, not copied.

The first heap-allocation variant failed its real size guard: an 8,388,608-byte aligned request occupied 8,454,144 bytes. Its failure receipt and diagnostic output are retained. The passing version uses exact page extents instead of assuming malloc bucket size. Root owns the pending native compile, old-adapter output comparison, physical launcher extension and actual model/cache measurements. The new additive adapter record is `checkpoint_aligned_selected_read_check`; prior ordinary adapter record output is intended to remain unchanged.
