### Faster widened Qwen27 tensor-parallel rounds

Qwen3.8 27B tensor-parallel owners with more than one lane now keep MLX fast fences instead of the event path. The event path added about 230 µs to each of a round's ~140 sealed sums, so a widened owner's single-request round took about 100 ms where a one-lane owner took about 67 ms; every round at every width now saves that time. The multi-lane stall that led to the event path predates the rule that never evaluates independent requests' collectives together.
