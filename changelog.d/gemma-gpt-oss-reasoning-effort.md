### Gemma 4 thinks when asked to, and GPT-OSS reasons at the effort you send

- Gemma 4 thinks for every reasoning effort but `none`, as `reasoning_effort` or `reasoning.effort` (it ignored the effort before, and its template doesn't think by default). An explicit thinking switch still wins.
- GPT-OSS renders each effort at the nearest Harmony level: `none`, `minimal` and `low` as `low`; `medium` as `medium`; `high`, `xhigh` and `max` as `high`. `high` rendered `medium` before, and `minimal`, `xhigh` and `max` reached the template as sent. Darkbloom's coordinator keeps OpenRouter's traffic at `medium` at most.
- Darkbloom's coordinator maps every effort the way this provider does, and both check the same 354 cases (`fixtures/prompt-contract/v1/reasoning_effort_vectors.json`).
