package store

import "time"

// VerificationTaskKind identifies a bounded coordinator verification task.
// Values are persisted, so additions must be backward-compatible.
type VerificationTaskKind string

const (
	VerificationTaskSecurityInfo VerificationTaskKind = "security_info"
	VerificationTaskMDA          VerificationTaskKind = "mda"
)

// VerificationTaskState is the durable scheduler state. A row is scheduling
// metadata only; it is never evidence and cannot grant trust.
type VerificationTaskState string

const (
	VerificationStateWaitingChallenge VerificationTaskState = "waiting_challenge"
	VerificationStatePending          VerificationTaskState = "pending"
	VerificationStateRunning          VerificationTaskState = "running"
	VerificationStateBackoff          VerificationTaskState = "backoff"
	VerificationStateCompleted        VerificationTaskState = "completed"
)

// VerificationPriority is ordered from most urgent to least urgent.
type VerificationPriority int16

const (
	VerificationPriorityFirstOrExpired VerificationPriority = iota
	VerificationPriorityRecovery
	VerificationPriorityRefresh
)

// VerificationOutcome is a fixed, low-cardinality terminal/attempt outcome.
type VerificationOutcome string

const (
	VerificationOutcomeNone            VerificationOutcome = "none"
	VerificationOutcomeSuccess         VerificationOutcome = "success"
	VerificationOutcomeReused          VerificationOutcome = "reused"
	VerificationOutcomeTransient       VerificationOutcome = "transient"
	VerificationOutcomeTimeout         VerificationOutcome = "timeout"
	VerificationOutcomePostureMismatch VerificationOutcome = "posture_mismatch"
	VerificationOutcomeInvalid         VerificationOutcome = "invalid"
	VerificationOutcomeCancelled       VerificationOutcome = "cancelled"
	VerificationOutcomeError           VerificationOutcome = "error"
)

// VerificationJob is durable retry/claim state keyed by the registration-bound
// Secure Enclave identity and task kind. Provider/session IDs are deliberately
// absent. ClaimOwner identifies a coordinator process, never a provider.
type VerificationJob struct {
	SEPubKey      string
	Serial        string
	UDID          string
	Kind          VerificationTaskKind
	State         VerificationTaskState
	Priority      VerificationPriority
	RetryStage    int
	PreviousDelay time.Duration
	NextAttemptAt time.Time
	LastOutcome   VerificationOutcome
	// ReopenPending records that a newer connection settled its challenge while
	// an older coordinator still owned the durable claim. The old result releases
	// this row back to pending instead of completing current-generation work.
	ReopenPending  bool
	UpdatedAt      time.Time
	ClaimOwner     string
	ClaimExpiresAt *time.Time
}
