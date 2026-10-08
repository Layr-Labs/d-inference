# Native scratch-tail correction

Private source candidate, 2026-09-15. No MAIN edits, compiler, test binary, native RDMA, GPU, model or remote execution at freeze.

The existing mesh and ring send paths copy a logical prefix into a reused scratch buffer, then post the entire buffer through `Connection::post_send`. Short or final frames can therefore transmit uninitialized or stale tail bytes. The same pattern exists in P2P and collective staging.

The four-file patch adds `stage_send_frame` plus a small `SharedBuffer::stage_send` wrapper, and replaces exactly 14 send-buffer copy sites: eight mesh sites and six ring sites. The helper validates the element count before multiplication or writes, copies the same typed elements as before, then sets every remaining posted byte to zero. Full frames have no tail clear. Zero-logical ring slices become fully zero frames. Invalid count or nonempty null input refuses before mutation.

Posted SGE lengths stay equal to buffer capacity. Receive sizes, copy counts, work-request IDs, pipeline slots, polling, send completion and buffer reuse rules remain unchanged. The caller stages only at the existing initial/refill point; fan-out shares one already prepared frame. All receive/completion/reduction code is byte-exact after reversing the 14 substitutions. This clears padding; it does not encrypt valid payload, erase storage after retirement or make raw reductions eligible for required-encryption mode.

Shorter WQEs may be compatible with an oversized receive buffer, but would add different receive-byte-count semantics and zero-length sends for inactive collective slices. This candidate preserves the current protocol without relying on unqualified hardware behavior. The posted tail is zero padding, not additional ciphertext. Fresh authenticated keys, caller coverage, record budgets and native allocation admission remain separate.

## Actual-header CPU regression

`Tests` compiles the actual proposed `rdma.h`, mesh and ring headers, including the actual SharedBuffer staging/SGE and Connection post/poll methods. Only verbs, allocation/registration and connection creation are fake. Sentinel-filled aligned scratch buffers, exact WQE copies and delayed completion observations make stale bytes and premature send-buffer reuse observable. Fake receives require the same full SGE length as the sender and copy the posted bytes before completion. Both request and completion queues must drain before fixture teardown.

The candidate checks cover bounded typed/zero-logical staging; mesh P2P short/full/reuse/multi-frame; ring P2P with one and two wires; mesh gather/reduce/scatter; ring reductions/scatter including inactive slices and pipeline refill. They check valid payload/output, zero tails, exact posted lengths, output guards and drained completions. A separately compiled original-header fixture must reproduce the sentinel-tail failure; it accepts only that specific expected regression. Sanitizers are enabled. These are deterministic in-process CPU simulations of verbs, not hardware or throughput results.

After a root compiler grant:

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/jaccl-native-send-tail-draft-20260915/Tests/run.py --output /Users/developer/DarkbloomDev/cluster-research/jaccl-native-send-tail-checks-1-20260915
```

Two standalone clang++ compilations and two CPU runs execute sequentially, with 60-second compile and 10-second execution bounds, the existing exact unreaped-child runner, fresh receipts and source revalidation. No SwiftPM, MLX library build, GPU or network is used. Actual two-peer RDMA compatibility and encrypted-record wire qualification remain required before deployment.
