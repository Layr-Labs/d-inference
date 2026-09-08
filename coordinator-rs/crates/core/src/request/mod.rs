//! The request lifecycle state machine (plan sections 7.2, 9.2, 11.8, 13).
//!
//! One pure reducer ([`machine::RequestMachine`]) owns one logical request:
//! its attempt set, absolute deadlines, funding compare-and-swap,
//! first-content commitment, cancellation ladder, and terminal disposition.
//! Events ([`events::Event`]) are observations delivered by the surrounding
//! task; effects ([`effects::Effect`]) are descriptions of work — nothing is
//! executed here.

pub mod effects;
pub mod errors;
pub mod events;
pub mod machine;
pub mod types;

pub use effects::Effect;
pub use errors::TransitionError;
pub use events::Event;
pub use machine::{RequestMachine, MAX_ATTEMPTS};
pub use types::{
    AttemptKind, AttemptRecord, AttemptState, Deadlines, HedgeOffer, Phase, PreparedFacts,
    RequestOutcome, ReviewReason, TerminalOutcome, TerminalSummary,
};
