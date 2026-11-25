### Inkling 2 with thinking off reports no reasoning tokens

With thinking turned off (`reasoning.enabled` false, `enable_thinking` false,
or an effort of `none`, `off` or `0`), Inkling 2 Mini still writes a short
thought, which the provider never returns. That thought is no longer counted
in `completion_tokens_details.reasoning_tokens`, which is now 0 for these
requests; its tokens still count in `completion_tokens`, so the billed total is
unchanged. Thinking on, and reasoning another model withholds because the
client declined to receive it (`reasoning.exclude`, `include_reasoning: false`),
count as before.
