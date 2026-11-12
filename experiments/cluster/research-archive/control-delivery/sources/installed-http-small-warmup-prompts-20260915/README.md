# Exact small warmup prompts

These two plain-text prompts contain exactly **512** and **1024** tokens after the pinned Qwen3.5-9B full chat template is applied with `enable_thinking:false`, `add_generation_prompt:true`, and tokenization with `add_special_tokens:false`. The requests preserve `reasoning_parser:qwen3` and request 128 outputs. These are CPU tokenizer observations, not server counts or physical warmup results.

The preparation is the prior `installed-http-long-prompts-20260915` algorithm with only its two target counts and preparation schema changed. It retains the same MLX source-prefix family, copyright/license, instruction, footer, exact tokenizer bytes, complete Jinja template, and explicit single-user rendering cross-check. It adds no repetition or padding. Small excerpts can omit functions mentioned by the instruction; the instruction explicitly says to report missing implementation rather than invent it.

`fixtures/preparation.json` pins every tokenizer/source input, the Python executable, Python/tokenizers/Jinja versions, selected source prefix and all fixture bytes. `lineage.json` pins the original generator. `preparation-1` and `verification-1` retain actual CPU invocations, exits and streams. Both passed with empty stderr. No model, MLX, compiler, network, download, or physical inference was used.

Independent recount command (uses the already installed Python environment):

```sh
/Users/developer/.local/share/uv/tools/vllm-mlx/bin/python -B \
  /Users/developer/DarkbloomDev/cluster-research/installed-http-small-warmup-prompts-20260915/verify.py \
  /Users/developer/DarkbloomDev/cluster-research/installed-http-small-warmup-prompts-20260915/fixtures
```

For a future physical run, compare the saved `.rendered.txt` through the installed `/tokenize` endpoint with every saved `.ids.json` ID before timing generation. That utility preflight does not generate tokens or load a new request state. Retain the timed chat response's actual usage separately; it must report the declared exact input count. The existing 8192-token fixture remains unchanged in the original long-prompt directory. These source excerpts do not establish representative workload coverage or causal speedup.
