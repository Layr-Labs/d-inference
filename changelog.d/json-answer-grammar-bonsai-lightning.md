### Valid JSON answers on Bonsai 2 and Nemotron 3.5 Lightning

- A tool-free JSON `response_format` request on the Bonsai 2 builds (27B and 9B) or on Nemotron 3.5 Lightning, whose
  prompt starts in the answer (thinking off, the JSON default on Bonsai), is now sampled under the JSON-answer
  grammar the Qwen 3.5 family already uses: for schemas inside the constrained subset the answer is one JSON value of
  the requested schema, with no prose, no extra or missing keys and no raw newline inside a string. On our checks,
  Lightning answers with thinking off missed the schema 8 times in 72.
- Requests whose prompt opens a thought, and requests served by a cluster pair, keep today's prompt-only steering.
- Like Qwen's, these answers decode without MTP and without the generation loop guard, and a value cut at
  `max_tokens` or by a `stop` sequence fails the format check.
- `DARKBLOOM_JSON_ANSWER_GRAMMAR=qwen` (or `0`/`off`) keeps the grammar to the Qwen types.
