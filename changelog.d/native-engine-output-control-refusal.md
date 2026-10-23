### Logprobs on GLM-5.3-Flash and typed refusals on native engines

- Serve `logprobs` and `top_logprobs` (up to 20 alternatives) on GLM-5.3-Flash through the coordinator relay. A logprob row samples through the engine's ordinary sampler and never speculates; while it decodes, the requests batched with it decode without MTP, as beside a GLM image request.
- Refuse `logprobs` on MiMo V2.6, and token constraints on either native engine, with 400 `invalid_request` before any reservation. The engine's own refusal reached the coordinator as a 500 `generation_failure`, which counts as provider sickness: two such requests cooled every provider of the model and its requests without tools were shed as 429 "no provider … is available right now" for five minutes.
