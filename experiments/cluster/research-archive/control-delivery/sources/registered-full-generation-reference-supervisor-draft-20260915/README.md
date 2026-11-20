# Registered full-generation reference supervisor

This private one-request owner invokes the reviewed registered 9B/27B full-model reference. It does not enter product serving. Root owns deployment and actual model execution. The parent has been exercised only with fabricated Python children; no model or network was run by this author.

`run_reference.py`, `PipeWorkers`, `WorkerSpec`, the bounded file/JSON helpers and the resource gate are byte-identical to `full-generation-reference-supervisor-draft-20260915`. The derivative changes only model/request admission and native report bindings. The old package and its evidence remain frozen; copied `cpu-check-1`/`cpu-check-2` are historical, not new validation.

## Inputs and command

The job has the old exact fields plus `registered_model`, `prompt_count` and `chunk_size`, under `private_registered_full_generation_reference_job_v1`. It must be canonical sorted compact JSON with a single final LF and an explicit SHA-256. Unknown fields, bool-as-int, unsupported models/cuts, duplicate/unsorted stops, overlapping source/run paths and changed build pins are refused.

Both registered models admit P1...8192, C1...512, O1...128 and at most 256 sorted unique stop IDs in vocabulary 0...248319. The configured chunk may exceed the prompt; the executed final chunk is shorter. 9B cuts are 4/8/12/16; 27B also permits 32. The native timeout remains 300 seconds and parent 315. No environment override or JACCL transport is introduced.

`example-job.json` is the root's ready-to-run 27B input: UUID `20801ced-ca29-4faf-b71a-9ebbe1886a14`, P32/C16/O128, cut32, empty stops. It points to the verified 48 GB deployment:

- native: `/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915/native`
- prompt: sibling `inputs/prompt.ids.json`
- model: `/Users/developer/DarkbloomDev/models/Qwen3.8-27B`
- fresh output: sibling `runs/short-27b-1`

The prompt packet in `request-input/` is byte-exact from root's short-input package; it contains no model weights. Example-job SHA-256 is `984b013420e00c620842446af1d22b28eca941a50994875d3e64c809b5fc1e85`.

From the deployed supervisor directory, root invokes:

```sh
/usr/bin/python3 -B run_reference.py --job /absolute/supervisor/example-job.json --job-sha256 984b013420e00c620842446af1d22b28eca941a50994875d3e64c809b5fc1e85 --launcher-sha256 EXACT_THIS_DIRECTORY_MANIFEST_SHA256
```

The complete frozen supervisor directory must be copied, because the existing launcher verifies all declared member bytes. The parent directory for the fresh run must already exist. Repeated runs require a fresh `run_dir`, canonical job bytes and job hash; no run output is overwritten.

The native argv contains exactly 12 flag/value pairs: mode `qwen-registered-full-generation-reference`, model directory, archived prompt path/SHA, request UUID, cut, output count, stops, registered profile, prompt count, chunk size and timeout. Environment remains only PATH, LANG and the same three arithmetic variables.

## Build and source bindings

The exact three runtime members remain `cluster-inference`, `mlx.metallib` and `mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal`, plus their `bundle.json`. Bundle tree, file identity/owner/mode/size/hash and executable mode are checked before launch and again afterward. Python reads pinned configuration/manifest metadata and the prompt, not tensor payloads.

| Binding | SHA-256 |
|---|---|
| Native | `0b734e2c74c848f5a5a9dd9b8cd1df1d2fc35b761914950d242a3cf00fe8427b` |
| Metallib | `2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2` |
| Paged-attention source | `4ad3ff17d8c6e0a3b5b8a91e9151447f84e36cb3688ed204e1e7eb6838dd9149` |
| Build manifest | `e1f084798764bf9851512d8acb50ff62982e5e3d3b04cd947c165ff19d4396c1` |
| Bundle manifest | `c96dce44ca3e23d276ae2810e08abb5a3fac966606b00fbdebccf166d2c9b27e` |

`reference_profiles.py` is a closed table derived from the pinned native specification and model definition. `native-source-pins.json` records the exact DTO, profile, frame, capture and state-geometry sources. This table is metadata, not an execution/resource permit. The parent retains false claims for independent source-to-binary, loaded-metallib, Plan, numerical and physical-transfer verification.

## Output and lifecycle contract

Exactly admitted then report must arrive, followed by exact LF, stdout/stderr EOF, empty stderr and native exit 0. The actual PID and bundle path must match. The original 32 MiB line/160 MiB combined live caps remain, with the tighter native 16 MiB cap on each accepted record. All streams and owner arguments/environment are retained in exclusive 0600 files. Postflight mutation, resource refusal, incomplete/malformed output, extra records or deadline expiry causes failure and owned-group cleanup.

The request/profile/prompt fingerprint is independently reproduced from admitted values. Completion may be `length` or an admitted `eos`: an earlier stop cannot be ignored; actual outputs must be 1...requestedO. Completed frames are `ceil(P/C)+actualO-1`; committed frontier is `P+actualO-1`; reserved context remains `P+requestedO`. Each token's exact final-prefill/decode frame and complete-vocabulary metadata is checked.

The full final row must contain 248320 finite numeric values with BF16 shape/width and the same digest as the final token evidence. Per-token rows are compact metadata/digests, not retained full values. Python does not reconstruct BF16 bytes or independently validate greedy math.

Final state has exactly 72 entries for 9B or 144 for 27B: every global layer/component, dtype, shape and logical byte count is checked at the actual frontier. Full attention uses global layers 3,7,...; other layers have conv/SSM components. The state fingerprint is recomputed from this metadata and the reported opaque per-component digests. This establishes metadata/digest consistency only, not independent state-value correctness or candidate numerical parity. Plan and parameter-layout digests remain opaque but bound across records.

The unchanged gate retains six-GiB actual-free, AC and reported-zero-swap checks and raw refused samples. Native independent allocator/load/request checks remain authoritative. Sampling is not a continuous minimum or a whole-process peak proof. Cleanup records native leader reaping and owned-group fencing; it does not independently reap all descendants. Postflight checks still run after a deadline/resource error. A failed request cannot be labeled a completed reference.

## CPU validation

Run `/usr/bin/python3 -B -m unittest -v test_reference_supervisor test_registered_reference`.

`cpu-check-registered-1` records 18 tests passing in 3.429 seconds with 17 actual fabricated Python children. It preserves the previous lifecycle, exact-EOF, output corruption, native nonzero/stderr, deadline, resource/postflight and file-mutation coverage. New tests exercise both model vectors, short/partial/max frame geometry, EOS 1/2/128, wrong model/source/request/token-row metadata, missing/duplicate/wrong-layout state, and the root's exact short 27B packet. No native/model/compiler/network work occurred.
