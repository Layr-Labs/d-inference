### Tool schema `$ref` resolution on the local API

- The render-safe repair typed every `$ref` node as a string, so a reference to an object reached the model as a
  string (TOOLSCHEMA-REF: Gemma read tau2-bench's airline `flights` / `passengers` / `payment_methods` items as
  `type:STRING`). The coordinator now resolves routed requests for the models its allowlist names; the local API
  (`LocalChatUploadResponder`: chat, chat batch and Responses) applies the same rules before decoding, so a local
  request renders as a routed one does.
- `inline` replaces local, non-recursive references with a copy of their target, all or none per schema, within
  2,048 JSON values and 24 levels per schema and 16,384 per request; whatever is not inlined keeps its `$ref` and
  gets its target's type, never `string`. `typed` only types them. The shared fixtures (`Tests/ProviderCoreTests/
  Fixtures/toolschema-refs/`, byte for byte the coordinator's) pin both implementations.
- `DARKBLOOM_TOOLSCHEMA_REF_RESOLVE_MODELS` takes the coordinator's syntax; unset is the coordinator's default list
  (Gemma 4 26B and Qwen 3.8 27B), `off` keeps today's behaviour. GLM-5.3 keeps raw schemas and MiMo at most `typed`.
  Routed bodies are left as the coordinator sent them.
