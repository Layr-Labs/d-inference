# Selected-stage payload read cache change

The candidate starts from frozen resident JACCL worker 7b4ae5d7. Its four-file
change makes selected Qwen stage payload reads opt into descriptor-local
`F_NOCACHE` before materialization. File verification, selected bytes, compact
allocation checks, model math, resource gates, protocol and request timing are
unchanged. Existing full-reference/default loader reads keep their cached policy.
No global cache or interface setting is changed by the loader.

The runtime owns each descriptor until source release. Rehashing retains an
explicit uncached payload policy; failed policy setup propagates before selected
materialization. Closing the descriptor ends the policy. Existing cached pages
are not evicted, so a previously populated cache may still need separate test
setup. This source change does not itself prove memory savings.

Source snapshot: `records/source-snapshot.json`, 426 members, SHA256
`894d27fe66b4b370af46d4c7490a5d3f4624947bd5da8a9825e88b30c6f2a05f`.
Delta: `records/source-delta.json`. Original JACCL workspace is unchanged.
Independent review: `../resident-payload-cache-review-20260915/source-review.json`.

The added `checkpoint_read_policy_check` in adapter-check uses a tiny real file
and CPU descriptor IO to compare cached/uncached bytes, repeated opt-in, rehash,
range rejection and in-place mutation detection. No model arrays are loaded by
that check. Root owns build, CPU execution, package creation and actual physical
measurement; their receipts are added separately after completion.

Observed reason for this candidate: attempt4 rank0 load added about 2.184 GB of
anonymous pages and 1.719 GB of file-backed pages before the 6 GiB actual-free
floor stopped it. After native retirement, anonymous growth nearly disappeared
while 1.751 GB of file-backed growth remained. This supports cached selected
reads as a material contributor; it does not identify ownership of each page.
