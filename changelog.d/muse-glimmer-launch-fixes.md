### Muse Glimmer 30B serving fixes before listing

- Muse Glimmer 30B loads and is advertised only on an Apple M5 Ultra. The provider reports the runtime capability `muse_glimmer_v1` only when the chip is an M5 Ultra and its Metal device names one. Both Muse identities require `apple_m5`, `mlx_nax` and `muse_glimmer_v1`. Without them, the model is left out of advertisement and a load is refused with the typed, permanent ineligibility before any disk or loader work; the refusal names the requirement.
- A tool call the model gets wrong is never a provider failure. Tool channels are read as the reference servers read them:
  - Values are typed by the caller's declarations: a string keeps its text, a local `$ref` is resolved, and `6.0` is an integer where only an integer is admitted.
  - An `auto` choice without `strict` returns the call as generated.
  - A `strict` tool or a forced choice refuses a noncompliant call as HTTP 422.
  - A tool frame with no call is 422 on every request, where it was 500.
  - `DARKBLOOM_MUSE_GLIMMER_REFERENCE_TOOL_CALLS=0` restores the strict parser, still as 422.
- The prompt matches the reference render:
  - Tool schemas render as the caller sent them, without the ingress repair's render types or marker key.
  - A request with a `developer` message has its system messages merged as vLLM merges them.
  - The JSON `response_format`, `tool_choice: none` and forced-choice instructions are appended to the caller's system message or last user turn, instead of adding a system block that replaced the template's default one.
  - `DARKBLOOM_MUSE_GLIMMER_REFERENCE_PROMPT=0` renders the earlier prompt.
  - The prompt goldens gain 14 cases; the 36 earlier cases are unchanged.
- The loop guard and its exit from a looping reasoning message know Muse Glimmer's Onyx channels and ATEM call frame. Both are off by default until an A/B on the model; add `muse_glimmer` to `DARKBLOOM_LOOP_GUARD` and `DARKBLOOM_LOOP_EXIT_THINKING` to turn them on.
- `scripts/muse-glimmer-qualification/live_probe.py` checks a live endpoint's penalties, stop strings, seed, `n`, streaming usage, finish reasons, logprobs and error shapes. Its README lists the request fields that turn drafting off.
