### Changed

- Add default-off native reasoning budgets for supported local Nemotron Super and MiMo routes. Positive `reasoning.max_tokens` now reaches the SDK sampler, closes the thought at its token limit and continues the answer within the original total output ceiling. Unsupported routes and conflicting thinking-off controls remain refused.
- On by default since 0.10.13 (measured on Nemotron 3.5 Super in its ON state); `DARKBLOOM_NATIVE_REASONING_BUDGET=0` restores 0.10.12's refusals.
