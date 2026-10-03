package api

// Shared request preprocessing for the consumer inference handlers.
//
// handleChatCompletions and handleGenericInference (completions + Anthropic
// messages) historically carried byte-identical copies of the request prelude
// (body read → tool-schema normalize → JSON parse → model-required → per-key
// model allowlist) and the vision/tools fail-fast gates. This file factors those
// shared sequences into single helpers so the two handlers can't drift. The
// helpers preserve EXACT behavior — identical error types, messages, params, and
// status codes — and write the terminal response themselves, signalling the
// caller to return via ok=false / handled=true.
//
// The prelude parses the body exactly once. Every later rewrite (stop
// normalization, alias resolution, reasoning policy, runtime defaults,
// max_tokens bound, …) mutates the decoded map and marks the forwardBody
// dirty; the bytes are serialized once, lazily, when the first consumer of
// the provider-bound body asks for them.

// 16 MiB
