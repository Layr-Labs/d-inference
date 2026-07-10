//! The identity and fencing set flattened into every request-scoped v2 frame.

use serde::{Deserialize, Serialize};

use crate::json_v2::ids::{
    AttemptId, CoordinatorEpoch, DispatchNonce, JobId, LeaseId, RequestDigest, SessionEpoch,
};

/// Identity and fencing fields carried by every request-scoped v2 frame
/// (plan §10.2). Flattened into each frame's top level.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct RequestScope {
    pub job_id: JobId,
    pub attempt_id: AttemptId,
    /// Present on every frame at or after `prepared`. `prepare` has no lease
    /// yet. [`FrameV2::validate`](super::FrameV2::validate) enforces presence
    /// per frame kind.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lease_id: Option<LeaseId>,
    pub session_epoch: SessionEpoch,
    pub coordinator_epoch: CoordinatorEpoch,
    pub dispatch_nonce: DispatchNonce,
    pub request_digest: RequestDigest,
}
