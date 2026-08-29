//! Pure fleet decision logic (plan section 11).
//!
//! The live `FleetActor` (server crate) owns the mutable maps and mailboxes;
//! everything decision-shaped lives here so it can be property-tested and
//! replayed:
//!
//! - [`admission`]: the single `admit` operation — hard gates, advisory
//!   filter, scoring, permit description, typed decision (11.1-11.4).
//! - [`scoring`]: calibrated latency-cost ranking with near-tie spread (11.4).
//! - [`calibration`]: clamped windowed-median prediction correction (11.4).
//! - [`health`]: per (provider, model) circuit machine + machine-wide
//!   security fence (11.6).
//! - [`permits`]: bounded prepare-permit accounting with hard expiry and
//!   idempotent release (9.2.10, 11.3).
//! - [`hedge`]: the global bounded prepare-hedge budget (11.8).
//! - [`model_presence`]: the canonical revision-fenced model-presence view
//!   (10.7).

pub mod admission;
pub mod calibration;
pub mod health;
pub mod hedge;
pub mod model_presence;
pub mod permits;
pub mod scoring;
