//! `POST /v1/chat/completions` (plan §7.1, §23.2).
//!
//! The body is parsed ONCE into
//! [`ChatCompletionRequest`](request::ChatCompletionRequest) (unknown fields
//! preserved through a flattened map for forward compatibility, plan §15.4),
//! normalized (alias resolution, output bound injection, trait detection),
//! and handed to one supervised request task. The response commits only on
//! first content: pre-content failures map to typed HTTP errors and any
//! provider retries stay invisible (plan §7.8).
//!
//! Module layout: [`handler`] (ingress ordering + task spawn), [`request`]
//! (parse/normalize), [`stream`] (SSE path), [`aggregate`] (non-streaming
//! aggregation). The ingress-ordering and SSE-flush guarantees are
//! documented on the owning modules.

mod aggregate;
mod handler;
mod request;
mod stream;

pub(super) use handler::chat_completions;
