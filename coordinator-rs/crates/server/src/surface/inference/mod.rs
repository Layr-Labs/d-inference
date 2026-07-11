//! Bounded compatibility adapters for inference API surfaces.
//!
//! Every request is lowered to the existing chat-completions JSON consumed by
//! the pilot dispatcher. Every response is adapted from authenticated chat
//! bytes after the same source commitment boundary; no adapter proxies to the
//! legacy Go coordinator.

mod anthropic;
mod canonical;
mod completions;
mod error;
mod limits;
mod responses;
mod transport;

pub use anthropic::{AnthropicStreamAdapter, adapt_anthropic_nonstream, parse_anthropic_request};
pub use canonical::{
    AdaptedStreamFailure, AdapterContext, CanonicalChatRequest, CanonicalChatStream,
    ChatCompletion, ChatSseEvent, ChatUsage, InferenceSurface,
};
pub use completions::{
    CompletionsStreamAdapter, adapt_completions_nonstream, parse_completions_request,
};
pub use error::AdapterError;
pub use limits::{
    MAX_BODY_BYTES, MAX_CONTENT_PARTS, MAX_JSON_TOTAL_STRING_BYTES, MAX_JSON_VALUES, MAX_MESSAGES,
    MAX_MODEL_BYTES, MAX_OUTPUT_TOKENS, MAX_PROMPTS, MAX_RESPONSE_BYTES, MAX_SSE_EVENT_BYTES,
    MAX_SSE_EVENTS, MAX_TOOL_CALLS_PER_MESSAGE, MAX_TOOLS,
};
pub use responses::{ResponsesStreamAdapter, adapt_responses_nonstream, parse_responses_request};
pub use transport::{
    JSON_CONTENT_TYPE, SEALED_CONTENT_TYPE, TransportRequest, open_transport_request,
};
