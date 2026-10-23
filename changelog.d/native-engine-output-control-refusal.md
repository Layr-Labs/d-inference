### Typed refusal of logprobs on native engines

- Refuse `logprobs` and token constraints on a model whose engine is native-tracked (GLM-5.3-Flash and MiMo V2.6) with 400 `invalid_request` before any reservation. The engine's own refusal reached the coordinator as a 500 `generation_failure`, which counts as provider sickness: two such requests cooled every provider of the model and its requests without tools were shed as 429 "no provider … is available right now" for five minutes.
