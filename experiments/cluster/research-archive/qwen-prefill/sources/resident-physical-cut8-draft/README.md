# Resident physical cut8/24 derivative

This private launcher selects registered 9B cut8/24, serial_v1, the unchanged raw 8192 prompt, chunk 512, one output, and one warmup plus three measured requests. It preserves the frozen V4 launcher and all previous run failures. No native code, resource floor, or networking configuration changes are included.

The runtime delta is `selected_source.py` plus `physical_common.py`, `rank_validation.py`, and `cut12_pair_final.py`. Historical helper filenames remain unchanged. `runtime.patch` shows the three replacements and new helper against V4. The copied 67 V4 members are individually hash-checked against `prior-v4-manifest.json`; exact unchanged files are listed in `checks.json`.

`selection/catalog.json` is the existing Foundation-only native Plan export, SHA906de56e50cde991a979743fb88b7db6bd8c93306a153a6af1fb761665cb75ee. It is not a model-run output. The selected record binds native Plan/stage/construction hashes, layer ranges, exact source/local parameter mappings, and state component ownership. The registered retained metadata independently supplies complete tensor shapes, dtypes and byte counts. The helper replays active/inert/layout/storage recipes, preserves F32, and checks complete source conservation. Its cut12 regression reproduces both old qualified semantic receipts exactly.

Cut8 expects 233/694 active tensors,1,545,572,992/3,492,468,608 logical active bytes and 18/54 final state components. The full source remains 927 tensors/5,038,041,600 bytes and the full final state 72 components/319,946,784 bytes. Logical metadata does not establish peak allocation or actual free memory.

The source-offset manifest pin is carried forward only from the old qualified artifact source. The fixture lacks offsets, so this is not a new offset replay. Old cut12 Plan, construction, stage, active layout/mapping and storage hashes are not reused as cut8 expectations. Candidate payload/state values are not exported: this checker retains the existing digest-comparison scope, independently reconstructs only the saved full-reference BF16 row and known offsets, and keeps all performance/independent-candidate-byte claims false.

The final checker slices the unchanged full reference by validated selected global ranges, checks the exported component sets and exact registered geometry, and requires disjoint complete 72-component coverage. Its state/final fingerprints are unchanged. All wire envelope bytes/domain hashes, 16 frames,ACKs,selected-token packet,post-stop release,sourceLoadReceipt hashing and timing checks remain unchanged. The actual source receipt retains selected-read operational accounting.

All remote process ownership, startup/cleanup, EOF/exit handling, bounded stderr, output caps, raw source/bundle/artifact checks, 300s native/315s owner deadlines and four-request barriers are unchanged. Both Macs still require actualfree>=6GiB,pressure<=2,absolute zero reported swap and AC; native resource admission remains authoritative. Cache-off controls and aligned-read accounting remain unchanged. This package does not authorize lowering a floor or treating transport exit as remote retirement.

Run the CPU suite:

```sh
python3 -B -m unittest -v test_physical test_retry_stderr test_selected_read_accounting test_allocator_policy test_selected_cut
```

All 31 tests passed (20 inherited unchanged, 11 added). These use fabricated Python child processes and retained metadata/reference files, not new native/model/SSH execution. The new cases cover stale cut/Plan, complete source mappings, preserved F32, malformed metadata/raw pins,18/54 slicing,missing/duplicate/reordered/wrong-owner state and full 72 union. The historical reference files were already qualified; no upcoming cut8 output has been accessed.

Root supplies a new absolute plan file based on `example-plan.json`, including exact existing native/package/bundle pins and two explicit run paths. It contains placeholders intentionally; no paths or binary hashes are guessed. The existing native worker already accepts cut8. Root intends its existing d904 binary; that full hash must still match the supplied package and bundle.

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/resident-physical-cut8-draft/run_physical.py \
  --config /ABSOLUTE/ROOT-PREPARED-CUT8-PLAN.json \
  --output /ABSOLUTE/NEW-LOCAL-RESULT-DIRECTORY
```

Use the frozen manifest SHA for deployment and root verification. Each host retains its local native ownership and cleanup evidence; this experimental SSH launcher is not the product authenticated remote-owner endpoint. The local direct-child Swift pipe owner is a separate frozen artifact. Physical execution success and throughput remain unqualified by this source/CPU package.
