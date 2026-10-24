### Nemotron 3.5 Super speculates for sampled and controlled requests

- Sampled Super requests (temperature above zero) now speculate with the embedded MTP head through exact target-prefix acceptance. Each accepted draft equals the token the target samples with the request's own sampler and seed, so output is unchanged; before, every sampled request decoded one token per step.
- A Super request the engine cannot draft for (a `stop` string, a repetition, frequency or presence penalty, or `logit_bias`) now decodes one ordinary token per step beside requests that speculate. Before, one such request turned speculation off for every request in the same step.
