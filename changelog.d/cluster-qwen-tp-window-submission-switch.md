### Faster Qwen tensor-parallel verification: windows evaluated whole

Qwen tensor-parallel speculative verify windows are evaluated whole instead of
being submitted to the GPU one decoder layer at a time. On two M5 Ultra Macs
serving Qwen3.8 27B this makes a single request about 18 % faster (60 against
51 tokens per second) and four concurrent requests about 5 % faster, with
identical outputs. `DARKBLOOM_QWEN_TP_WINDOW_LAYER_SUBMISSION=1` (diagnostic,
never forwarded to an installed rank) submits windows by layer again; both
ranks bind the choice into their load agreement.
