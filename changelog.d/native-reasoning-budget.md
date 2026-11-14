### Native reasoning budgets for Nemotron Super and MiMo

- Add default-off native reasoning budgets for supported local Nemotron Super and MiMo routes. Positive `reasoning.max_tokens` now reaches the SDK sampler, closes the thought at its token limit and continues the answer within the original total output ceiling. Unsupported routes and conflicting thinking-off controls remain refused.
