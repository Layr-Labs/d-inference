### Changed

- Add native reasoning budgets for supported local Nemotron Super and MiMo routes. Positive `reasoning.max_tokens` now reaches the SDK sampler, closes the thought at its token limit and continues the answer within the original total output ceiling. Unsupported routes and conflicting thinking-off controls remain refused. On by default since 0.10.13 for Nemotron 3.5 Super (measured there in its ON state); MiMo keeps 0.10.12's refusal unless `DARKBLOOM_NATIVE_REASONING_BUDGET=1`; `0` restores 0.10.12 for every family.
