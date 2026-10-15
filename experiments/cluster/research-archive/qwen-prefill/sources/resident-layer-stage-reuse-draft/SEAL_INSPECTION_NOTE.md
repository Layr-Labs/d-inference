# Seal inspection clarification

Supplement to the frozen source plan, 2026-09-14; no implementation/execution.

The named qkv/z/b/a views created by `sourceView` can remain lazy: subsequent
forwards use the unregistered fused parent, and `evaluatedBufferInfo()` returns
nil for an unevaluated child. The proposed seal must not evaluate these views
merely to obtain offsets, and must not infer a shared allocation from matching
BufferInfo values. Record the authorized CPU parent/child wrapper identities
and row-range recipe at the existing sourceView creation point, alongside the
provider’s cached signature. A read-only sealing check can then compare those
identities and the fixed expected shape/dtype/row map after the priming request,
using already-evaluated parent metadata if available. This adds bookkeeping to
the existing transform, not another concatenation or a parameter readback.

The original verified materialization receipt remains historical source proof.
The runtime seal establishes that this exclusively owned model underwent only
the source-controlled permitted transform; it is not a cryptographic proof of
current device contents. Unknown in-place parameter mutation is outside that
ownership contract and cannot be detected by wrapper identity alone. The new
resident factory must therefore retain the model privately and expose no raw
parameter/mutation API. Keep a same-shape replacement negative fixture and do
not use ordinary `freeze()` as an immutability guarantee.
