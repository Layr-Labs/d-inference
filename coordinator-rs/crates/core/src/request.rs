use crate::ids::{AttemptId, JobId, LeaseId};
use thiserror::Error;

/// Process-local request lifecycle (illustrative minimal set from the plan).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RequestState {
    Reserving,
    Admitting,
    Preparing { attempt: AttemptId },
    FundingPrepared { attempt: AttemptId, lease: LeaseId },
    Starting { attempt: AttemptId, lease: LeaseId },
    AwaitingContent { attempt: AttemptId, lease: LeaseId },
    Streaming { attempt: AttemptId, lease: LeaseId },
    AwaitingTerminal { attempt: AttemptId, lease: LeaseId },
    Finalizing,
    Finished,
}

#[derive(Debug, Clone)]
pub enum RequestEvent {
    Reserved { job: JobId },
    Admitted { attempt: AttemptId },
    Prepared { attempt: AttemptId, lease: LeaseId },
    StartAuthorized { attempt: AttemptId, lease: LeaseId },
    Started { attempt: AttemptId, lease: LeaseId },
    FirstContent { attempt: AttemptId, lease: LeaseId },
    ProviderTerminal { attempt: AttemptId, lease: LeaseId },
    FinalizeDone,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum TransitionError {
    #[error("invalid transition from {from:?} on {event}")]
    Invalid { from: String, event: &'static str },
}

impl RequestState {
    pub fn transition(self, event: RequestEvent) -> Result<Self, TransitionError> {
        use RequestEvent::*;
        use RequestState::*;
        match (self, event) {
            (Reserving, Reserved { .. }) => Ok(Admitting),
            (Admitting, Admitted { attempt }) => Ok(Preparing { attempt }),
            (Preparing { attempt }, Prepared { attempt: a, lease }) if attempt == a => {
                Ok(FundingPrepared { attempt: a, lease })
            }
            (FundingPrepared { attempt, lease }, StartAuthorized { attempt: a, lease: l })
                if attempt == a && lease == l =>
            {
                Ok(Starting { attempt: a, lease: l })
            }
            (Starting { attempt, lease }, Started { attempt: a, lease: l })
                if attempt == a && lease == l =>
            {
                Ok(AwaitingContent { attempt: a, lease: l })
            }
            (AwaitingContent { attempt, lease }, FirstContent { attempt: a, lease: l })
                if attempt == a && lease == l =>
            {
                Ok(Streaming { attempt: a, lease: l })
            }
            (Streaming { attempt, lease }, ProviderTerminal { attempt: a, lease: l })
                if attempt == a && lease == l =>
            {
                Ok(AwaitingTerminal { attempt: a, lease: l })
            }
            (AwaitingTerminal { .. }, FinalizeDone) | (Finalizing, FinalizeDone) => Ok(Finished),
            (AwaitingTerminal { .. }, _) => Ok(Finalizing),
            (from, event) => Err(TransitionError::Invalid {
                from: format!("{from:?}"),
                event: event_name(&event),
            }),
        }
    }
}

fn event_name(event: &RequestEvent) -> &'static str {
    match event {
        RequestEvent::Reserved { .. } => "Reserved",
        RequestEvent::Admitted { .. } => "Admitted",
        RequestEvent::Prepared { .. } => "Prepared",
        RequestEvent::StartAuthorized { .. } => "StartAuthorized",
        RequestEvent::Started { .. } => "Started",
        RequestEvent::FirstContent { .. } => "FirstContent",
        RequestEvent::ProviderTerminal { .. } => "ProviderTerminal",
        RequestEvent::FinalizeDone => "FinalizeDone",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ids::{AttemptId, JobId, LeaseId};

    #[test]
    fn happy_path() {
        let attempt = AttemptId::new("a1");
        let lease = LeaseId::new("l1");
        let mut st = RequestState::Reserving;
        st = st
            .transition(RequestEvent::Reserved {
                job: JobId::new("j1"),
            })
            .unwrap();
        st = st
            .transition(RequestEvent::Admitted {
                attempt: attempt.clone(),
            })
            .unwrap();
        st = st
            .transition(RequestEvent::Prepared {
                attempt: attempt.clone(),
                lease: lease.clone(),
            })
            .unwrap();
        st = st
            .transition(RequestEvent::StartAuthorized {
                attempt: attempt.clone(),
                lease: lease.clone(),
            })
            .unwrap();
        st = st
            .transition(RequestEvent::Started {
                attempt: attempt.clone(),
                lease: lease.clone(),
            })
            .unwrap();
        st = st
            .transition(RequestEvent::FirstContent {
                attempt: attempt.clone(),
                lease: lease.clone(),
            })
            .unwrap();
        st = st
            .transition(RequestEvent::ProviderTerminal {
                attempt: attempt.clone(),
                lease: lease.clone(),
            })
            .unwrap();
        st = st.transition(RequestEvent::FinalizeDone).unwrap();
        assert_eq!(st, RequestState::Finished);
    }

    #[test]
    fn rejects_skip_to_streaming() {
        let err = RequestState::Reserving
            .transition(RequestEvent::FirstContent {
                attempt: AttemptId::new("a"),
                lease: LeaseId::new("l"),
            })
            .unwrap_err();
        assert!(matches!(err, TransitionError::Invalid { .. }));
    }
}
