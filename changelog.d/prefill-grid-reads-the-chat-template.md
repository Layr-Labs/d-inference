### An opt-in prefill grid that reads message boundaries from the chat template

- `DARKBLOOM_CBV2_CANONICAL_PREFILL_GRID` cuts every text prompt into chunks that end at a multiple of the grid. A prompt that extends an earlier one is then cut into the same chunks over the tokens they share. It is off by default, and unset keeps the chunking of earlier versions.
- With the grid on, each model reads its message-boundary rule from its own chat template when it loads, so a chunk also ends where an assistant message opens and closes. The rule is checked on two-turn prompts first; a template that fails the check gets no rule and is not changed. `DARKBLOOM_CBV2_CANONICAL_BOUNDARIES` sets the rule by hand.
- The provider accepts a grid only when it is a multiple of 128 tokens and fits the plain chunk, half the step budget and the mixed-step cap. GLM5Next and Nemotron Super local serving ignore both keys, and prompts with media keep ordinary chunking.
- With the grid on, one long prompt on an idle engine runs in grid cells and not in the wider solo stripe. Its prefill speed has not been measured on this version.
- Both keys apply under `start --foreground` only, and setting either one turns off the reviewed serving and deadline profiles, as every `DARKBLOOM_CBV2_*` key does.
