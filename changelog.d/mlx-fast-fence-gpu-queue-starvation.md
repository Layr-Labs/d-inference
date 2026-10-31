### One GPU stream per decode graph, and no GPU-on-GPU fence spins

With MLX fast fences (`MLX_METAL_FAST_SYNCH=1`) a widened Qwen 3.8 27B
tensor-parallel owner could stop at its first multi-row plain decode (the c14,
c17 and c39 stalls). MLX cast each batched 4-bit projection's bfloat16 scales
and biases to float32 on the thread's default GPU stream instead of the stream
the caller passed, and mlx-swift runs everything else on its own process-wide
stream, so that decode graph ran on two GPU streams. A fast GPU fence wait is a
kernel that spins on its queue until the other queue's timestamp arrives, and
Metal does not promise that the other queue runs meanwhile, so both queues
stopped. The casts (and MLX's other helper ops that dropped the caller's
stream) now stay on the caller's stream, and a GPU stream never spins on
another GPU stream: it waits on a shared event, while the CPU <-> GPU
collective waits keep the spinning fast path. Synchronization only: tokens are
unchanged. Widened Qwen 3.8 27B owners stay on the event path until a two-Mac
acceptance with fast fences passes on this fix.
