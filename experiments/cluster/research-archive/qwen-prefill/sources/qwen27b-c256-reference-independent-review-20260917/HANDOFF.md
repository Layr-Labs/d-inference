This is a source-only, read-only replay helper for the fixed 27B C256 ordinary reference. Its initial source was written before reading actual output. Root subsequently requested an independent read of the failed first run; that observation is below. The helper itself has not been executed. It launches no child, opens no network connection, and reads no model or binary payload. Its only write is one create-only findings JSON outside the input/evidence directories.

After the actual copy, run and collection are terminal, root can review this source and run:

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/qwen27b-c256-reference-independent-review-20260917/review.py --output /Users/developer/DarkbloomDev/cluster-research/qwen27b-c256-reference-independent-review-20260917/findings-1.json
```

The helper consumes the existing `Experiment/inputs-1`, prepared `Experiment/reference`, its `physical-copy-1`, `physical-run-1`, and `physical-collect-1` receipts, and exactly eight returned files. Source and prepared input pins are fixed in source-pins.json. Actual native PID, tokens, report hashes, collected file identities and results are read only at execution; none are prospective constants.

Checks:

- Copy/run/collection exit 0, actual reap, absent outer group, no timeout kill or retained cleanup errors, bounded elapsed time, exact remote program SHA, retained stdout/stderr hashes, and the copy's 65-file deployment join.
- Exactly the eight producer-defined returned paths; base64, byte count, SHA and remote stat identity for each collection member; exact local returned bytes and terminal's three native stream pins. Empty native stdin/stderr and exactly two LF-terminated stdout records.
- Exact native argv, environment, PID/PGID, 300/315-second native/parent settings; completed terminal, actual native exit 0, reap, group fence, complete output, no cleanup/postflight errors and unchanged source-input assertion.
- Exact prepared 8192-token prompt, C256, O128, cut16, empty stops, MTP off, request ID, native/bundle metadata and Plan. The unchanged five-module reference contract checks all 128 token records, 159 frames, frontier8319, final full-row shape and 144 state entries/fingerprint.
- Every resources.jsonl observation and the separate outer preflight: derive actual free from raw vm_stat page size times Pages free, require >=6 GiB; parse raw pressure exactly1, swap exactly0 and AC power. Preserve reported/native and raw OS minima separately. Check sample duration <=10 seconds, count <=2000, three prelaunch samples, one final postflight, and monotonic ordering within the supervisor resource log only.
- Empty journal and no matching process names at preflight/collection. These are retained observations, not fresh live inspection.

Important schema limits:

1. Existing `reference_resources.validate_local` permits pressure0..2; this helper deliberately requires actual raw pressure1. No source policy is changed.
2. Collection captures journal size through lstat and filters ps names; it does not record the journal inode or hold its lock during collection. Preflight briefly verifies an empty canonical regular inode under flock, then releases it before native launch. There is no same-inode lifetime lease or descendant-reaping proof here.
3. The native terminal records natural exit/reap/group fence/EOF and configured deadlines, but no explicit watchdog-armed/fired field. The pinned safe PipeWorkers keeps its watchdog through cleanup. Successful source-derived paths plus terminal fields are the available proof; the helper does not invent additional fields.
4. Discrete resource observations do not establish a continuous process peak or new placement margin. Outer preflight and supervisor clocks are not subtracted; no cross-host clock arithmetic occurs.
5. The reference parser checks report identity and state/row metadata. It does not numerically compare the reference to another implementation or reconstruct row bytes from values. State component digests remain opaque. These facts cannot qualify an encrypted candidate or a throughput measurement.
6. The findings intentionally omit `passed`, use `requiresIndependentRootReview: true` and `qualificationGranted: false`, and are not accepted directly by `bind_reference.py`. Root must inspect actual evidence and write its own review. Failure emits partial factual findings plus the first failed check and exits1; complete replay exits0 without approval.

Actual failed-run observation, independently read after root's follow-up: all eight collection base64/size/SHA joins agree. All305 resources.jsonl records independently parse to pressure1, zero swap, AC and >=6GiB; minimum8,156,823,552B, initial31,514,279,936B, postflight31,773,720,576B. Native stderr reports all1847 tensors authorized, loaded=true, requestAdmitted=true; actual-free8,159,133,696B versus required8,200,058,523B, a40,924,827B deficit. Allocator limit48,962,627,174B exceeds required28,574,907,479B by20,387,719,695B. Active16,490,278,960B and cache6,035,033,484B are actual scalar observations at refusal. This proves the actual-free budget refused; it does not prove a cache purge or rerun would complete.

The terminal SHA42f0821251b59779268300244bc3cf09106e701cb6da61cde54339ac8f94ad22 reports status failed, native[-9], one admitted record, outputComplete=false; leader reaped/group fenced/source unchanged with no cleanup errors. Collection has no matching active process and journalBytes0. Native stderr SHAce9523d2ed19136c0f503d346cc2b80ab702ce6ff760543b72e59f15d16b81cd; resources SHA43b720b9181fe0fbb4d02eda8d0c94547729ba5bc430952553463d9d49889c3e. There is no accepted final report or expected token sequence. This helper rejects the failed outer run before any success-only contract binding. Future retries need a separately reviewed path/job binding; the current helper cannot silently consume another run.

Validation at preparation: source AST, small source/input pin checks and the explicitly requested read-only failed-evidence replay above. No helper execution, fabricated tests, compiler, physical operation or model access was performed. No prior evidence, source freeze, installed tree or MAIN file was modified.
