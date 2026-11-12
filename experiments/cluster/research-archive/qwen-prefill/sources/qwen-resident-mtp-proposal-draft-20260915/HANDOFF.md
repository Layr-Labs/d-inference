# Private committed-history and single-proposal increment

The eight-file runtime overlay passes native typechecking against the exact selected-MTP-load source snapshot. The Foundation lifecycle check passes 14 cases. The tiny real-forward fixture also compiles, but its first GPU attempt was refused before child launch: actual free memory was 1,172,488,192 bytes and swap used was 1,147,928,576 bytes. No new model forward, trusted history or proposal has executed. MAIN and the previously qualified MTP-off worker remain unchanged.

The actual 48GB selected-load result remains separate: 809 target tensors plus 34 head/replica tensors loaded and retired successfully. It established payload/ownership behavior, not generation. This overlay advances the source path from those assets to captured target history and one unaccepted assistant proposal.

## Runtime changes

- `Qwen35ClusterMTPForward` adds a residual-ingress SPI that returns pre-final-norm hidden from exactly one existing target trunk call, beside its ordinary output.
- `QwenLayerStageSession` adds explicit captured prefill/decode methods. `CBv2OwnedRequestState` evaluates the extra hidden root with existing output/KV/recurrent roots before commit. The old nil-capture path is preserved byte-for-byte by the recorded inverse check.
- `QwenLayerStageMTPCapture` transfers a hidden frame once, only after local state and schedule commit.
- `QwenResidentMTPProposalControl` requires exact prompt history after both frame ACKs and one target token/continue decision after both ACKs. It binds the single proposal to request, agreement, round, seed, frontier and token chain. It never labels a proposal accepted.
- `QwenResidentMTPRequestResources` combines the existing target allowance, actual assistant allocation projection and named capture/proposal allocations. The tiny projection SPI reuses the existing allocator policy. The initial owner is restricted to verified cut4/BF16/serial registered 9B assets, P≤8192, C≤512, O2…128, an explicit ≤300s deadline and a sufficient retained reservation.
- `QwenResidentMTPRequest` owns the target session, assistant state, pending capture and raw carry. It uses the unchanged assistant normalization/history/forward/discard/release methods. Discard is terminal; retirement releases local state and cancels the incomplete target session. The outer owner still retains charges until peer retirement/fencing.

No capability, MTP-enabled agreement, worker/Provider flag, source receipt, default serving path or target verification transaction is added. The budget names expected allocations; it does not claim to predict all kernel workspace. See `TRANSACTIONS.md` for the required target-first prefix reconciliation and bilateral publication barrier.

## Checks and retained corrections

The 17-source Swift 6 warnings-as-errors Foundation check passed one complete three-chunk lifecycle plus 13 refusals, including incomplete ACKs, wrong history/request, stopped seeds, duplicate proposals and discard retry. These are control fixtures, not native or physical ACK evidence.

Native build1 failed after 200.803s on Swift's nonescaping callback borrowing rule. A synchronous `withoutActuallyEscaping` wrapper fixes that concrete compiler error without storing a callback. Independent source review also found a nested native-error precedence gap; the captured path now checks its inner MLX handler before shape validation. Both prior sources and patches are retained.

Corrected native build2 passed in 22.945s with 3,054 source pins unchanged and Mach-O minos 26.2. The separate tiny fixture target passed in 24.316s with 3,057 pins unchanged. It compares ordinary/captured final-stage outputs and chunked/single-batch assistant history using fabricated small weights; it cannot exercise the registered 9B resource gate. Its entry explicitly uses GPU because the existing GatedDelta implementation may use a Metal kernel. Both logical peer ACKs in that fixture are fabricated.

The first tiny run used the unchanged reviewed `PipeWorkers` and `ResourceGate`, matched executable/metallib and a 60s owned-child deadline. It failed at prelaunch and postflight resource admission, with zero children. The first receipt's `all([])` reaped/fenced booleans are explained in a separate scope supplement; the raw receipt is unchanged and the next runner labels zero-child outcomes explicitly.

## Key identities

- Required selected-load source snapshot: `e6b6126fc28258843e3ba7e85ccb12857e005ecde6c8e2f49d95dc6b8334e37d` (3,048 files).
- Corrected native snapshot: `7ded72b4974c8137174dca610b2aeac2c1ad9bf80d0858942824375889cf1d7b`.
- Typechecked selected-load executable containing the proposal module: `8c2ec8d28cb0f3bef341424cec19b137618ceed865376b68c093031dac0445b6`.
- Tiny snapshot: `1a864620e394154603d87043a086cf761bbb8a935d7ff09e9f2b17e7da778dd8`; tiny executable: `a86aabe2bf9bad092dcccdb0d8e8cddc0baeb0fba7dc93e663fc089df628853a`.
- Matched metallib: `2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2`.
- Corrected source inverse: `c850c95127adacab0a7ee81481d8d6e8f9043b96098d1d7f8ebec75282a4ba71`.
- Independent review: `0db70e41a5e6863d6686dec0545978ce338fb3b4d5d1289f9ac263fac9f357a7`; closure supplement: `4cd06ecd281bb225bc8029b86e6d4d6a75055fbef5d4805797e29353b45f1eb8`.

After an admissible tiny run, the next physical gate is a short registered 9B request with actual producer boundaries and ACKs, one proposal after the first target token, then ordinary target token2 and clean stop. That compares proposal versus target without consuming the draft or claiming speculative acceptance. Prefix transaction implementation remains separate and must precede MTP-on output publication.
