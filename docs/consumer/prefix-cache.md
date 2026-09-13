# Make repeated text requests cache-friendly

> Last updated: 2026-09-13 · commit `3cf03209a`

This how-to helps API consumers preserve identical prefixes across related text
requests. Reuse depends on the model, a valid checkpoint, provider capacity and
routing; sharing a prefix does not guarantee a hit.

## Prerequisites

Use a model with supported prefix caching and keep requests under the same
account. Follow the [API quickstart](quickstart.md) for authentication and SDK
setup. See the [cache architecture](../architecture/prefix-cache.md) for current
model support and the [routing explanation](../architecture/cache-aware-routing.md)
for scope and proof requirements.

## Steps

1. Keep repeated system instructions and reference material byte-for-byte
   consistent where their meaning is unchanged. Reuse the same tool definitions
   and their order instead of reconstructing equivalent schemas differently.
2. Put the changing question after that shared context where the application's
   semantics permit. Keep per-request timestamps, random identifiers and
   unrelated changing metadata out of the shared prompt prefix.
3. Preserve conversation order, tool-call/result relationships, model selection
   and reasoning controls. Do not change these merely to improve the hit metric.
4. Send repeated work while its checkpoints can still be reused. The
   [SSD reference](../reference/ssd-kv-cache.md#size-and-eviction-rules) defines
   retention and resource limits.

For an application where instructions and reference material already belong in
one system message, construct each request from the same shared value:

```python
shared_context = "Answer from the following reference.\n\n" + reference_document

def messages_for(question):
    return [
        {"role": "system", "content": shared_context},
        {"role": "user", "content": question},
    ]
```

Do not promote untrusted user content to a system message; use the role and
placement your application requires. The example only makes an existing stable
system context reusable.

## Verify

Check `usage.prompt_tokens_details.cached_tokens` in the completion response.
For streaming, request usage with `stream_options.include_usage` and inspect the
final usage-bearing event. Compare the same workload's TTFT and cached-token
share over multiple requests; a single miss does not establish a failure.

Operators can additionally compare the per-model cache opportunity counters,
proof rejection reasons and donation outcomes described in
[cache-aware routing](../architecture/cache-aware-routing.md#observed-demand-and-soft-prefix-affinity).
Repeated-prefix demand is advisory telemetry and does not count as a hit.

## Troubleshooting

- A changing early prefix prevents reuse of everything after that change.
- An identical prefix can miss after expiry, eviction, proof rejection, or
  routing to a different available machine.
- A cached-token count measures reused prompt work, not a measured number of
  seconds saved or guaranteed end-to-end delivery.

## Related

- [API quickstart](quickstart.md) — authenticate and send requests.
- [Prefix-cache architecture](../architecture/prefix-cache.md) — supported models and reuse mechanics.
- [SSD cache reference](../reference/ssd-kv-cache.md) — retention and resource limits.
- [Cache-aware routing](../architecture/cache-aware-routing.md) — evidence, routing and diagnostics.
