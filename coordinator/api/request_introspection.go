package api

// request_introspection.go holds helpers for introspecting and lightly
// reshaping inbound inference request bodies before routing/dispatch:
// token and cost estimation (routing vs billing), media/tool detection,
// remote media-URL rejection, and private routing-field stripping. Most are
// pure helpers with no Server
// state; the pre-dispatch media-URL rejection (rejectRemoteMediaURLs) hangs
// off *Server only to record rejection telemetry. Split out of consumer.go
// to keep the request-handling orchestrator thin.
//
// The estimates and media/tool detection share ONE walk of the message tree
// (introspectRequest → requestShape); estimatePromptTokens,
// estimateBillingPromptTokens, detectMediaRequirement, countMediaParts and
// requestHasTools are thin wrappers over it, so the handler can take every
// value from a single pass while callers that need just one keep their
// signature.
//
// Remote-media flow note: on the chat-completions surface the media resolver
// (media_resolve.go / coordinator/mediafetch) FETCHES remote image_url/video_url
// links and inlines them as data: URIs, so rejectRemoteMediaURLs only fires
// there when the resolver is disabled, the request is sender-sealed, or a
// remote reference sits in a shape the resolver does not fetch (see
// gateRemoteMediaPreDispatch). The generic (completions + Anthropic) surface
// keeps the unconditional rejection.
