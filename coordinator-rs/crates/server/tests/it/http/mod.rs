//! Chat-completions suites through the real router with every seam faked
//! at the frozen contracts: v1/v2 flows, limits, non-streaming, and
//! request-deadline discipline.

mod chat_v1;
mod chat_v2;
mod deadlines;
mod limits;
mod nonstream;
