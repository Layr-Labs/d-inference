# Independent CPU audit — same-hidden Qwen output boundary

All 12 raw result hashes and receipt copies, the driver identity, 130 archived
experiment source files, bundle files and empty stderr records were verified.
The audit reconstructed 24 native Float32/BF16 normalization arrays from their
recorded values (3,072 values total); every byte hash matches. Normalizing the
full final chunk and then selecting its last row is exactly equal to selecting
the hidden row first and normalizing it in every case.

Original full-projection and recomputed full-projection last-row hashes and
argmax values match in all 12 records. Narrowing the norm contributes zero
additional difference. Final chunks of one or two tokens are exact throughout.
With 32 final rows, vocabulary-projection shape alone changes results:

| Fixture | Dtype | Differing logits / 512 | Max absolute | Relative RMS |
|---|---|---:|---:|---:|
| tiny | BF16 | 272 | 0.0078125 | 0.0034386506097318836 |
| qwen27-heads | BF16 | 265 | 0.0078125 | 0.003467094469808891 |
| tiny | Float32 | 462 | 4.76837158203125e-7 | 2.6394162357561683e-7 |
| qwen27-heads | Float32 | 436 | 3.8743019104003906e-7 | 1.9233027382512607e-7 |

All 12 argmax choices agree. For qwen27-heads seed 31 prompt 96/chunk 32, both F32
and BF16 full-last/single-row projection hashes exactly match the archived tail
matrix’s ordinary-solo/CBv2-solo first rows. Matching model/config/layout/prompt,
seed, dtype and chunk identities were checked, and all error metrics were
independently recalculated from those archived raw logits.

The probe exports norm values but only hashes and metrics for logits. Thus
the two qwen27 tail cases permit independent head-metric recomputation; tiny 32-row
has no corresponding prior tail fixture and its head metrics remain
native-reported, with hash/record consistency checked. This demonstrates a
sufficient projection-shape explanation for the specific archived first-row
differences. It does not establish CBv2 trunk/cache byte equality, equivalent
model behavior, scheduler coverage, real-artifact quality, RDMA or performance.

`independent-cpu-audit.json` preserves the evidence hashes and checks;
`independent-cpu-audit.py` preserves the exact CPU-only script. The earlier
successful audit receipt/script remain as `independent-cpu-audit-initial.*`.
No native execution or source edit inside Git was performed by this audit.
