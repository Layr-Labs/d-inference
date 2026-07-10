//! Provider-side prepared-lease state machine (protocol v2).

use crate::ids::{AttemptId, JobId, LeaseId};
use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LeaseState {
    Idle,
    Preparing {
        job: JobId,
        attempt: AttemptId,
    },
    Prepared {
        job: JobId,
        attempt: AttemptId,
        lease: LeaseId,
        prefill_running: bool,
    },
    Running {
        job: JobId,
        attempt: AttemptId,
        lease: LeaseId,
        start_durable: bool,
        emitting: bool,
    },
    TerminalJournaled {
        job: JobId,
        attempt: AttemptId,
        lease: LeaseId,
    },
    Acknowledged,
    Aborted {
        lease: LeaseId,
    },
}

#[derive(Debug, Clone)]
pub enum LeaseEvent {
    BeginPrepare {
        job: JobId,
        attempt: AttemptId,
    },
    MarkPrepared {
        lease: LeaseId,
        prefill_running: bool,
    },
    Start,
    StartDurable,
    BeginEmit,
    JournalTerminal,
    AckTerminal,
    Abort {
        lease: LeaseId,
    },
    /// Prepared lease TTL elapsed before start authorization.
    ExpirePrepared,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum LeaseError {
    #[error("invalid lease transition")]
    Invalid,
    #[error("abort tombstone rejects start")]
    AbortTombstone,
    #[error("emission before durable start")]
    EmissionBeforeDurableStart,
}

impl LeaseState {
    pub fn transition(self, event: LeaseEvent) -> Result<Self, LeaseError> {
        match (self, event) {
            (Self::Idle, LeaseEvent::BeginPrepare { job, attempt }) => {
                Ok(Self::Preparing { job, attempt })
            }
            (
                Self::Preparing { job, attempt },
                LeaseEvent::MarkPrepared {
                    lease,
                    prefill_running,
                },
            ) => Ok(Self::Prepared {
                job,
                attempt,
                lease,
                prefill_running,
            }),
            (
                Self::Prepared {
                    job,
                    attempt,
                    lease,
                    ..
                },
                LeaseEvent::Start,
            ) => Ok(Self::Running {
                job,
                attempt,
                lease,
                start_durable: false,
                emitting: false,
            }),
            (Self::Aborted { .. }, LeaseEvent::Start) => Err(LeaseError::AbortTombstone),
            (
                Self::Running {
                    job,
                    attempt,
                    lease,
                    emitting,
                    ..
                },
                LeaseEvent::StartDurable,
            ) => Ok(Self::Running {
                job,
                attempt,
                lease,
                start_durable: true,
                emitting,
            }),
            (Self::Running { start_durable: false, .. }, LeaseEvent::BeginEmit) => {
                Err(LeaseError::EmissionBeforeDurableStart)
            }
            (
                Self::Running {
                    job,
                    attempt,
                    lease,
                    start_durable: true,
                    ..
                },
                LeaseEvent::BeginEmit,
            ) => Ok(Self::Running {
                job,
                attempt,
                lease,
                start_durable: true,
                emitting: true,
            }),
            (
                Self::Running {
                    job,
                    attempt,
                    lease,
                    ..
                },
                LeaseEvent::JournalTerminal,
            ) => Ok(Self::TerminalJournaled {
                job,
                attempt,
                lease,
            }),
            (Self::TerminalJournaled { .. }, LeaseEvent::AckTerminal) => Ok(Self::Acknowledged),
            (Self::Preparing { .. }, LeaseEvent::Abort { lease }) => Ok(Self::Aborted { lease }),
            (Self::Prepared { .. }, LeaseEvent::Abort { lease }) => Ok(Self::Aborted { lease }),
            (Self::Prepared { lease, .. }, LeaseEvent::ExpirePrepared) => {
                Ok(Self::Aborted { lease })
            }
            (
                Self::Running {
                    job,
                    attempt,
                    lease,
                    start_durable,
                    emitting,
                },
                LeaseEvent::Start,
            ) => Ok(Self::Running {
                job,
                attempt,
                lease,
                start_durable,
                emitting,
            }),
            _ => Err(LeaseError::Invalid),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_emission_before_durable_start() {
        let st = LeaseState::Idle
            .transition(LeaseEvent::BeginPrepare {
                job: JobId::new("j"),
                attempt: AttemptId::new("a"),
            })
            .unwrap()
            .transition(LeaseEvent::MarkPrepared {
                lease: LeaseId::new("l"),
                prefill_running: true,
            })
            .unwrap()
            .transition(LeaseEvent::Start)
            .unwrap();
        assert_eq!(
            st.transition(LeaseEvent::BeginEmit).unwrap_err(),
            LeaseError::EmissionBeforeDurableStart
        );
    }

    #[test]
    fn abort_tombstone_rejects_start() {
        let st = LeaseState::Idle
            .transition(LeaseEvent::BeginPrepare {
                job: JobId::new("j"),
                attempt: AttemptId::new("a"),
            })
            .unwrap()
            .transition(LeaseEvent::MarkPrepared {
                lease: LeaseId::new("l"),
                prefill_running: true,
            })
            .unwrap()
            .transition(LeaseEvent::Abort {
                lease: LeaseId::new("l"),
            })
            .unwrap();
        assert_eq!(
            st.transition(LeaseEvent::Start).unwrap_err(),
            LeaseError::AbortTombstone
        );
    }

    #[test]
    fn expire_prepared_becomes_abort_tombstone() {
        let st = LeaseState::Idle
            .transition(LeaseEvent::BeginPrepare {
                job: JobId::new("j"),
                attempt: AttemptId::new("a"),
            })
            .unwrap()
            .transition(LeaseEvent::MarkPrepared {
                lease: LeaseId::new("l"),
                prefill_running: true,
            })
            .unwrap()
            .transition(LeaseEvent::ExpirePrepared)
            .unwrap();
        assert!(matches!(st, LeaseState::Aborted { .. }));
        assert_eq!(
            st.transition(LeaseEvent::Start).unwrap_err(),
            LeaseError::AbortTombstone
        );
    }

    #[test]
    fn happy_path_to_ack() {
        let st = LeaseState::Idle
            .transition(LeaseEvent::BeginPrepare {
                job: JobId::new("j"),
                attempt: AttemptId::new("a"),
            })
            .unwrap()
            .transition(LeaseEvent::MarkPrepared {
                lease: LeaseId::new("l"),
                prefill_running: true,
            })
            .unwrap()
            .transition(LeaseEvent::Start)
            .unwrap()
            .transition(LeaseEvent::StartDurable)
            .unwrap()
            .transition(LeaseEvent::BeginEmit)
            .unwrap()
            .transition(LeaseEvent::JournalTerminal)
            .unwrap()
            .transition(LeaseEvent::AckTerminal)
            .unwrap();
        assert_eq!(st, LeaseState::Acknowledged);
    }
}
