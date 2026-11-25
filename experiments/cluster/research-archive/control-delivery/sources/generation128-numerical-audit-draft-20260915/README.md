# Private serial generation comparison

This CPU-only checker compares the fixed registered Qwen3.5 9B, cut-4, 8192-token prompt / chunk-512 / 128-output / empty-stop / MTP-off request. It accepts the retained full-reference output and two prospective recording sidecars. It never launches a worker, reads model weights, or imports a launcher.

It checks all 128 selected IDs on both ranks, the exact supplied agreement and source/Plan/stage identities, the final 143-frame / 8319-token frontier, and cross-rank token-chain equality. It reconstructs every byte of the final BF16 vocabulary row from the exported finite values, including signed zeros, then compares the bytes and checks the lowest-index maximum. The disjoint cut-4 state partitions must contain exactly 9 and 63 ordered entries. Their merge must match the reference's 72 entries and full fingerprint; eight Int32 position-offset hashes are reconstructed from 8319.

The candidate does **not** export intermediate logit rows or per-token frontier observations. Those comparisons remain explicitly false. The final token-chain hash is compared between ranks but cannot be independently reconstructed from the exported records. The other 64 state hashes are opaque comparisons: their underlying bytes are unavailable. Reference intermediate row hashes are also opaque. The storage commitment, build identities and numerical-policy identity are compared as reported/caller-supplied identities, not independently attested runtime provenance. Operational resource envelopes and retirement flags do not establish a new resource, process, physical-transport, performance, or external-TTFT qualification.

`recorded_math.py` is byte-identical to the frozen prior checker. `snapshot.py` contains the exact reviewed regular-file snapshot function. Input reads are bounded, reject leaf symlinks, check open-descriptor identity/stability, and recheck every input after comparison. Prompt tokens, row values and local input paths are not copied into the output receipt. Output is exclusive mode 0600. Exceptions produce a failed receipt and exit 1; an already existing output is never overwritten.

Run with Python 3.9 or newer:

```sh
/usr/bin/python3 -B audit_generation.py --packet /absolute/packet.json --packet-sha256 <raw-packet-sha256> --output /absolute/new-result.json
/usr/bin/python3 -B -m unittest -v test_audit
```

The packet is an object with exactly `schema`, `request_id`, `expected_agreement`, and `files`. The schema is `private_generation128_comparison_packet_v1`; the request ID is `6426b803-8b80-40ba-8944-b0f4b403a3cf`. `expected_agreement` is the complete native serial generation agreement descriptor, derived before candidate access. `files` has exactly `prompt`, `reference_stdout`, `rank0_evidence`, and `rank1_evidence`; each contains only `path` and lowercase `sha256`. Paths may be absolute or relative to the packet. Bounds are 64 KiB for the packet, 256 KiB for the prompt, 32 MiB for reference JSONL, and 16 MiB per candidate sidecar. The four inputs must be distinct files. The retained reference/prompt raw hashes are fixed in `audit_common.py`.

The original serial schema is closed. Any future lookahead agreement/result additions require a separate reviewed checker revision. This checker does not silently accept them.

Validation before candidate access: 16 fabricated CPU test methods passed under `/usr/bin/python3` (3.9); a separate replay of the already retained reference reconstructed its 496,640-byte final BF16 row and 72-entry state fingerprint. No candidate sidecar was read during implementation or these checks. The fabricated records are invented and do not constitute native correctness evidence.
