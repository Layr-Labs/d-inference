### Qwen27 tensor-parallel greedy choices without full-vocabulary gathers

Qwen27 tensor-parallel speculative decoding no longer moves complete vocabulary rows between the Macs for greedy work. Each draft step and each greedy verification column reduces a rank's vocabulary shard to its maximum and first index (plus a non-finite count when verifying), and one small exchange gives both Macs the same choice: the complete row's first maximum, with the lower index winning ties. Greedy verification also drops its separate choice broadcast. Sampled requests and logprobs still gather complete rows.
