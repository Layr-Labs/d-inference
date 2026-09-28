# Qwen MTP capture and history numerical check

> Last updated: 2026-09-15 · commit `605651bb9`

A fabricated small Qwen stage and MTP assistant completed actual GPU execution
on the 48 GB M4 Pro. Captured versus ordinary target outputs had zero maximum
difference, and chunked versus whole-prompt assistant history produced the same
unaccepted proposal with zero hidden-state difference. Registered-model MTP
generation and distributed target verification remain unfinished.

## What executed

The private fixture uses a four-layer final stage with hidden width 64,
vocabulary 128, five prompt tokens and chunks of two tokens. Target parameters
are fabricated float32 values; the one-layer assistant uses fabricated 4-bit
quantized weights. The fixture runs the actual Qwen stage and inline MTP
implementations on the GPU, not an arithmetic mock or a registered model load.

Two independent target request states process the same incoming residuals:
the ordinary stage path and the path capturing pre-normalization hidden states
for MTP. Two assistant histories observe those committed hidden states, one in
chunks and one as a whole prompt. After selecting the target's first token,
both assistants consume that seed and propose one token.

| Check | Actual result |
|---|---|
| Maximum difference in compared target outputs | 0 |
| Chunked versus whole-history proposal token | Both 15 |
| Maximum proposal hidden-state difference | 0 |
| Target committed frontier after proposal | Remains 5 |
| Target verification or acceptance | Not executed |
| Assistant request roots after explicit release | Zero materialized bytes and no evaluation targets |
| Both target request states after cancellation | Closed |

Frame and token acknowledgements in this fixture are fabricated locally. It
does not execute a remote rank, registered 9B resource admission, accepted-prefix
commit, rejected-suffix rollback, or an MTP on/off throughput comparison. The
ordinary/captured equality check is not an independent full-model oracle.

## Build, correction and cleanup

The first local launch was refused before starting a child because the local
Mac was using swap and lacked the required free memory. The check moved to the
48 GB Mac with the same resource guards.

The first remote child exited at assistant construction: the fabricated
configuration lacked the required nested `text_config`. A fixture-only change
wrapped the assistant configuration while preserving the flat target/plan
configuration. No proposal or target runtime code changed for this correction.
The original failure and binary remain retained.

The corrected release build passed, targets macOS 26.2 and preserves all
3,057 pinned source members during compilation. The actual child subsequently
exited zero with empty stderr. The parent reaped it, confirmed its process group
absent and recorded no cleanup errors. All 11 resource samples passed AC,
zero-swap, normal pressure and the six-GiB free-memory floor; minimum observed
actual free memory was 30.189788818 GiB. Returned files match hashes read back
from the remote host. This was a correctness check, not a timing benchmark.

| Artifact | SHA-256 |
|---|---|
| Corrected source snapshot | `8970c7869749883d5f58b2db9b83239e0835c2b2628ffe4cb9c45e55fae5d942` |
| Executed tiny binary | `d24d4c7d642c3fdde63b78c5c6edec7f7e11a4a8496963e79558a9d7aa45ed6e` |
| Matched metallib | `2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2` |
| Remote package manifest | `90c6f67778fdbd808787b75304faf6318561748587b7efcc435446a31e22625b` |

Raw evidence and the root review are retained privately in
`/Users/developer/DarkbloomDev/cluster-research/qwen-mtp-tiny-remote-20260915/revision-2/physical-1/`.
The next [MTP milestone](../design/distributed-cluster-execution-plan.md) is the
registered 9B proposal path with actual two-rank acknowledgements, followed by
shared target verification/rollback and measured MTP off/on generation.
