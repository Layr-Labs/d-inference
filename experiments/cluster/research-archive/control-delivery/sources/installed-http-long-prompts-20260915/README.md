# Installed Qwen HTTP prompts

Ready plaintext: `fixtures/prompt-4096.txt` and `fixtures/prompt-8192.txt`. Their **fully rendered chat counts are exactly 4096 and 8192 under the pinned Python tokenizer**. These are separate sizes of the same licensed MLX code-reading task, with unique source prefixes, complete MIT attribution, and an explicit truncation notice. They contain no repeated padding. They are development qualification inputs, not a representative workload suite.

The nineteen-member `fixture-manifest.json` is frozen at `5d97049c6998aaab9f1e85c3a56ab079642227f3d724e0e56c283fe6f3a2a240`. Nothing in this note changes those inputs or execution receipts.

| Fixture | Plaintext bytes | Fully templated Python tokens | First-content budget at this count |
|---|---:|---:|---:|
| `prompt-4096.txt` | 18,466 | 4096 | 14.096 seconds |
| `prompt-8192.txt` | 35,246 | 8192 | 18.192 seconds |

Preparation passed in 4.828 seconds; a fresh-process recount passed in 0.314 seconds, both with empty stderr. The recount uses the same pinned implementation; it is not an independent Swift-engine execution. No weights, compiler, model inference, remote action or network request ran here.

```sh
/Users/developer/.local/share/uv/tools/vllm-mlx/bin/python -B /Users/developer/DarkbloomDev/cluster-research/installed-http-long-prompts-20260915/verify.py /Users/developer/DarkbloomDev/cluster-research/installed-http-long-prompts-20260915/fixtures
```

To reproduce construction, run `prepare.py --output NEW_DIRECTORY` in the same environment. It refuses existing output and verifies five bounded retained inputs before tokenization. `prompt_inputs.py` owns exact pins and request settings; `prompt_render.py` renders the complete pinned Jinja template and compares its result with the exact single-user branch; `prepare.py` finds a real source-prefix boundary and accepts only an exact final count. Its bounded search never pads or assumes BPE counts are monotone. `verify.py` checks retained bytes, rendered text, request settings and complete token IDs.

Each fixture has plaintext, full rendered text, complete IDs, and the exact chat request body. Send the **plaintext** through the frozen HTTP client; do not send the rendered template as a chat user message. Keep `enable_thinking:false`, `reasoning_parser:"qwen3"`, greedy sampling, output cap 128, no tools/history/system turn, and the exact public model `Qwen3.5-9B`. Any change to these inputs requires recounting. Terminal server `usage.prompt_tokens` remains a separate observation and must agree before treating a run as this exact size.

## Source path and count boundary

Current MAIN `LocalChatRequest` decodes the top-level thinking control from the same body as the request. `templateAdditionalContext` makes the explicit false control effective in the absence of a nested override. `ProviderPromptContractPipeline` sanitizes the single string message; Qwen's leading-system normalization leaves this one-user case unchanged. `LocalTokenizerBridge` selects the pinned literal template, with generation prompt enabled and no truncation. The actual Swift tokenizer source renders with `lstripBlocks/trimBlocks` and encodes with `addSpecialTokens:false`.

For this input shape, both the complete pinned Jinja execution and a separate literal branch produce:

```text
<|im_start|>user\n + prompt.strip() + <|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n
```

Here `\n` denotes newline bytes, not literal backslash characters. The current Swift-Jinja normalization makes no change to this pinned template; it does not reference the request date. The reasoning parser controls output classification and does not add input tokens. `/apply-template` supplies no thinking context, so its count is not substituted for this path.

The CPU backend is tokenizers 0.22.2 with Jinja2 3.1.6 and Python 3.12.13. Raw tokenizer SHA is `87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4`; template SHA is `a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715`. The tokenizer has 248,077 entries including added tokens; the unchanged native model ID bound is 248,320. Detailed asset/executable hashes are in `fixtures/preparation.json`, while `source-map.json` pins the reviewed installed code and original licensed source recipe.

If root wants a pre-generation cross-check, the existing authenticated **`POST /tokenize`** accepts `{model:"Qwen3.5-9B", prompt:<saved rendered text>, add_special_tokens:false}` and returns `tokens`. Compare the whole returned array against the corresponding `.ids.json`. This uses the installed Swift tokenizer without another compiler or generation request; it does not independently execute the chat template. Only root performs this network operation. The later real chat's terminal usage tests the actual end-to-end token count. No Swift tokenization or server count is claimed by this preparation.

The 4K excerpt ends within `python/mlx/nn/layers/base.py`; the 8K excerpt includes that file and continues into `python/mlx/utils.py`, from MLX commit `ce45c52505c8158ea48d2a54e8caae05efd86bfe`. Source prefix byte counts and digests are retained. Missing final code is explicitly marked rather than completed or synthesized.
