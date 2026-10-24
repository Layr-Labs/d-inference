### Faster concurrent Qwen27 tensor-parallel verification

Concurrent Qwen27 tensor-parallel requests now share each quantized projection's weight pass when verifying their speculative windows, as long as the combined rows stay below MLX's vector-kernel limit for the device. Every request keeps the arithmetic it has alone. Draft proposals no longer need their own broadcast: both Macs read them from the same small exchange. A new `darkbloom-tp-mtp-profile-v1` worker line splits each round's time into draft, build, verify, gather, choose and settle.
