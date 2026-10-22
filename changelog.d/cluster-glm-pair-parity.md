### GLM pair: logprobs on lanes, reasoning exclusion and MTP metrics

- A GLM-5.3-Flash tensor-parallel pair serves `logprobs` / `top_logprobs` on batch lanes (it refused them with 503 when lanes were on), clamps `top_logprobs` to 20 as single-Mac does, accepts `reasoning: {"exclude": true}` (it answered 400), and reports MTP rounds, proposals and acceptances, its KV ledger, waiting requests and prefix-cache status on `/metrics`.
