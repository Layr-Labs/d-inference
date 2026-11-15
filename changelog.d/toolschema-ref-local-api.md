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
  Routed bodies are left as the coordinator sent them. The setting reaches an installed service.
- Hostile schemas can't crash or stall the provider: a reference to a non-schema value or through a pointer over
  1,024 bytes is kept (typed `object`); reference chains are followed at most 32 hops (a longer alias chain is no
  longer inlined) and 24 levels, without recursion along them; a request spends a bounded amount of work across all
  its tools; past a bound the references are kept and typed.
- `DARKBLOOM_TOOLSCHEMA_REF_RESOLVE_MODELS` reads its value as the coordinator does: `false`, `0`, `no` and `disabled`
  are off too, `pattern=off` excludes matching models, and an ignored entry is logged.
