package api

// media_resolve.go bridges the chat-completions handler to the mediafetch
// package: it turns remote http(s) image_url/video_url links into inline base64
// data: URIs on the coordinator (the trusted SSRF chokepoint) before the body is
// E2E-encrypted to a provider, so consumers can pass links the way they do with
// OpenAI instead of pre-encoding media. The provider keeps seeing only data:
// URIs — its hardened non-data: guard is unchanged (defense in depth).
//
// Two-phase flow (both phases chat-completions-only; the generic completions +
// Anthropic surface keeps the unconditional pre-dispatch rejection):
//
//  1. gateRemoteMediaPreDispatch — BEFORE token admission/billing. Fails fast
//     the cases that must never fetch: sender-sealed requests (fetching would
//     generate origin-observable egress correlated with a payload the sender
//     chose to seal), remote refs in shapes the resolver does not fetch
//     (Anthropic source blocks, input_image — which would otherwise dispatch
//     and be silently dropped by the provider, answering image-blind), and the
//     resolver-disabled fallback (legacy one-clean-400).
//  2. resolveRemoteMedia — AFTER token admission and the balance reservation,
//     so network I/O is gated behind the cost gates (an authenticated but
//     unfunded/over-quota request can never drive coordinator-side fetches).
//     The caller refunds the reservation on failure.
