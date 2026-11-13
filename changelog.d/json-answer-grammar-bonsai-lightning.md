### Valid JSON answers on Bonsai 2 27B and Nemotron 3.5 Lightning

- A tool-free JSON `response_format` request on Bonsai 2 27B or on Nemotron 3.5 Lightning, on one Mac, whose prompt
  starts in the answer (thinking off, the JSON default on Bonsai), is now sampled under the JSON-answer grammar the
  Qwen 3.5 family already uses: for schemas inside the constrained subset the answer is one JSON value of the
  requested schema (no extra or missing keys, no raw newline inside a string). On our checks, Lightning answers with
  thinking off missed the schema 8 times in 72 before and 0 times after.
- Requests whose prompt opens a thought (Lightning's default), requests served by a cluster pair, and the Bonsai 2 9B
  keep today's prompt-only steering.
- Like Qwen's, these answers decode without MTP (a Lightning row sharing their decode step stops speculating
  meanwhile), and the provider checks them when generation ends: an answer that misses the schema at a natural stop
  is the typed `422` (`tool_noncompliance`); one cut at `max_tokens` ends as a normal `length` finish with its
  content as generated.
- The grammar keeps an answer inside the schema, not on topic: a model that wants a forbidden key may keep writing the
  string it is in until `max_tokens`.
- `DARKBLOOM_JSON_ANSWER_GRAMMAR=qwen` (or `0`/`off`) keeps the grammar to the Qwen types.
