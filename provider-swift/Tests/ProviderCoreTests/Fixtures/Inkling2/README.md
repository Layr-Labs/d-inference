# Inkling 2 Mini prompt-contract fixture

These files are unmodified copies from Thinking Machines'
[`thinkingmachines/Inkling-2-Mini`](https://huggingface.co/thinkingmachines/Inkling-2-Mini/tree/6e7c8248f75265bdd4fbab5273304243b5d8c2cb)
release, at immutable revision `6e7c8248f75265bdd4fbab5273304243b5d8c2cb`.
The model card declares the Apache License, Version 2.0
(<https://www.apache.org/licenses/LICENSE-2.0>); the release ships no separate
license file. No weights, tokenizer vocabulary or model runtime code are
included.

| File | Git blob at the revision | SHA-256 |
|---|---|---|
| `chat_template.jinja` | `cae99e08917fe3d9ff21551a7c9a835981c69032` | `53a9035f3255945704b5857657cfb00c1165090c0641c4f782a0cbf268cc16dc` |
| `config.json` | `b7de677835af1c95e3a8794bf2215b75ff7d9c3b` | `8216dd43157f5474cfff88f486a1e433fef703c674f694e485a86a761c412b1e` |
| `tokenizer_config.json` | `abf8fb60451e6c33d2cfa3c4dfab9f8c1e7516aa` | `bf09342d285139fd37ce10c70878af1d52cb390e9901e10248654293a80ee636` |
| `special_tokens_map.json` | `e4fe9735b528be1c630eb832d655fc8c4c2c309f` | `c16f44b3594563d82743ddb0417a2be1bfe3e2000dfad2da4b8f32554593e1a0` |
| `generation_config.json` | `1b5d49d129001d2be58c2f254bfae3221eab6d96` | `a08737c07a65a8fdf69f7cf086576210e5aad4b241437090b26d7b0c4f7905f7` |

`Inkling2PromptContractTests` renders the template through the provider's
template path (`TemplateRenderCheck` and the Transformers-compatible filters it
needs) and checks the rendered bytes, the configuration-derived cache layout
and the media policy against these files.
