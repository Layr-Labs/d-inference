package api

// Shared routing/capacity admission preflight for the consumer inference
// handlers.
//
// handleChatCompletions and handleGenericInference (completions + Anthropic
// messages) carried byte-identical copies of the self-route / prefer / public
// capacity-and-TTFT preflight: ~280 lines of QuickCapacityCheck → alias-capacity
// fallback → unservable shed → model-too-large → capacity 429 / queue-spill →
// no-eligible-provider shed → TTFT gate, each writing the exact same
// OpenAI-compatible rejections and routing.decisions metrics. The ONLY
// divergence (verified by diffing the two blocks) is the forward-body refresh
// after an alias fallback rewrites parsed["model"]: chat re-marshals its threaded
// rawBody (and, for the Responses API, re-lowers input→chat, which can itself
// fail with a 400), while the generic path rebuilds the body from parsed at
// dispatch time and needs no refresh. That single difference is threaded as the
// onModelFallback callback. Everything else is shared verbatim so the two
// handlers can't drift.
