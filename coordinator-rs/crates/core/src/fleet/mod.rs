//! Immutable fleet policy: state, admission, scoring, health, and calibration.

mod admission;
mod calibration;
mod health;
mod scoring;
mod state;
mod ttft;

pub use admission::{Admission, AdmissionDemand, AdmissionError, AdmissionKind, admit};
pub use calibration::{
    CalibrationBook, CalibrationError, CalibrationEstimate, CalibrationEvent, CalibrationKey,
    CalibrationPolicy, CalibrationValue, reduce as reduce_calibration,
};
pub use health::{
    HealthError, HealthEvent, HealthMode, HealthPolicy, HealthState, ProbeClaim,
    reduce as reduce_health,
};
pub use scoring::{
    Candidate, CostScore, ScoredCandidate, ScoringError, ScoringPolicy, rank, score,
};
pub use state::{
    CapacityError, CapacitySnapshot, FleetEvent, FleetSnapshot, FleetStateError, FleetUpdate,
    ProviderSnapshot, ProviderTombstone, reduce as reduce_fleet,
};
pub use ttft::{
    PrefillDecodeRatioMilli, TtftError, TtftGateMode, TtftOutcome, estimate_idle_ttft_microseconds,
    evaluate_ttft_gate,
};
