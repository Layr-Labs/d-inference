### Tool JSON as Transformers renders it, on request

A chat request that carries `"_darkbloom_template_json": "transformers"` (the
coordinator sets it per build) now shows Qwen 3.5, 3.6 and 3.8, Ternary
Bonsai 2, MiMo v2.6, GLM-5.3 and GPT-OSS their tool declarations, earlier tool
calls and tool results exactly as Hugging Face Transformers renders their chat
templates: members in the order the client sent them, `", "` and `": "`
separators, non-ASCII text and `/` as written, `null` arguments and `strict`
kept, and Python `True`/`None` where a template prints a value with `string`.
Before, they read sorted, compact JSON with escaped non-ASCII text and without
`null` arguments: on the Tau2 airline prompts 523 to 666 tokens fewer than the
reference. Nemotron 3.5 Lightning takes the order. Every other request renders
the same bytes as before. `DARKBLOOM_TEMPLATE_JSON=transformers` asks for every
request of the provider; `DARKBLOOM_TEMPLATE_JSON_LEGACY=1` turns it off.
