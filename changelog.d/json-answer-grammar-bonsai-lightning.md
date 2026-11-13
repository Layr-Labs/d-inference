### Valid JSON answers on Bonsai 2 and Nemotron 3.5 Lightning

- A tool-free JSON `response_format` request on the Bonsai 2 builds (27B and 9B) or on Nemotron 3.5 Lightning is now
  sampled under the JSON-answer grammar the Qwen 3.5 family already uses: the answer is one JSON value of the
  requested schema, with no prose, no extra or missing keys and no raw newline inside a string. Before, Lightning
  answers with thinking off missed the schema about one time in ten on our checks.
- Lightning's constrained rows don't speculate (as `stop` or penalty rows), so its JSON answers decode without MTP.
- `DARKBLOOM_JSON_ANSWER_GRAMMAR=qwen` keeps the grammar to the Qwen types.
