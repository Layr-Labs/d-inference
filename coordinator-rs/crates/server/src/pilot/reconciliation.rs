use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
    time::Duration,
};

use darkbloom_coordinator_protocol::v2::{
    AttemptId, AttemptIdentity, AttemptStatus, CoordinatorControlMessage, QueryAttempt,
};
use tokio::sync::oneshot;

use super::state::PilotSession;

struct PendingQuery {
    identity: AttemptIdentity,
    result: oneshot::Sender<AttemptStatus>,
}

/// Bounded rendezvous between recovery workers and historical provider
/// `attempt_status` responses.
pub struct AttemptQueryRegistry {
    maximum: usize,
    pending: Mutex<BTreeMap<AttemptId, PendingQuery>>,
}

impl AttemptQueryRegistry {
    pub fn new(maximum: usize) -> Self {
        assert!(maximum > 0);
        Self {
            maximum,
            pending: Mutex::new(BTreeMap::new()),
        }
    }

    pub async fn query(
        &self,
        session: &PilotSession,
        identity: AttemptIdentity,
        wait_for: Duration,
    ) -> Result<AttemptStatus, Arc<str>> {
        let attempt_id = identity.attempt_id;
        let (sender, receiver) = oneshot::channel();
        {
            let mut pending = self
                .pending
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if pending.len() >= self.maximum {
                return Err(Arc::from("attempt reconciliation registry is full"));
            }
            if pending.contains_key(&attempt_id) {
                return Err(Arc::from("attempt reconciliation is already pending"));
            }
            pending.insert(
                attempt_id,
                PendingQuery {
                    identity: identity.clone(),
                    result: sender,
                },
            );
        }
        let send = session
            .writer
            .try_send_control_json(&CoordinatorControlMessage::QueryAttempt(QueryAttempt {
                identity: identity.clone(),
            }));
        if let Err(error) = send {
            self.remove(attempt_id);
            return Err(Arc::from(error.to_string()));
        }
        let result = tokio::time::timeout(wait_for, receiver).await;
        self.remove(attempt_id);
        match result {
            Ok(Ok(status)) => Ok(status),
            Ok(Err(_)) => Err(Arc::from("attempt reconciliation registry closed")),
            Err(_) => Err(Arc::from("attempt reconciliation response timed out")),
        }
    }

    pub fn resolve(&self, status: AttemptStatus) -> Result<bool, Arc<str>> {
        if !status.digest_shape_is_valid() {
            return Err(Arc::from(
                "attempt status has invalid terminal digest shape",
            ));
        }
        let pending = self
            .pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&status.identity.attempt_id);
        let Some(pending) = pending else {
            return Ok(false);
        };
        if pending.identity != status.identity {
            return Err(Arc::from(
                "attempt status identity differs from the historical query",
            ));
        }
        let _ = pending.result.send(status);
        Ok(true)
    }

    fn remove(&self, attempt_id: AttemptId) {
        self.pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&attempt_id);
    }
}
