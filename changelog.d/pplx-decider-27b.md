### pplx-decider decision requests

- Providers can serve `EigenLabs/pplx-decider-v1-27b-MLX-4bit`
  (`pplx-decider-v1-27b`, `model_type` `pplx_decider_qwen35`) on Apple M5
  with NAX, with the same runtime requirement as the Qwen 3.8 27B target.
- A decision request (`model`, `state`, `questions`, optional `images`)
  returns calibrated `choice`, `noul` and `score` answers with
  `input_tokens`/`output_tokens` usage, through the coordinator connection and
  the local endpoint's new `POST /v1/decisions` route.
- Chat requests to a decision model, and decision requests to any other model,
  are refused with 400. `decision_config.json` is part of the hashed model
  files.
- On the local endpoint, the short name `pplx-decider-v1-27b` and the full id
  both resolve to the advertised pack.
