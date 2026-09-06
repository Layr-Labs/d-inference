// Package outcomes defines versioned, prompt-free incoming-request accounting.
// It is independent of the sampled waterfall profiler and routing policy.
package outcomes

import "time"

const SchemaVersion = 1
const MaxAttempts = 64

// Record is one coordinator-minted request, selected into windows by ReceivedAt.
// Revision orders snapshots, never request counts. FinalizedAt is handler exit;
// ObservedAt can advance later when a parked provider terminal arrives.
type Record struct {
	CoordRequestID          string          `json:"coord_request_id"`
	SchemaVersion           int             `json:"schema_version"`
	Revision                int64           `json:"revision"`
	ReceivedAt              time.Time       `json:"received_at"`
	FinalizedAt             *time.Time      `json:"finalized_at"`
	ObservedAt              time.Time       `json:"observed_at"`
	Endpoint                string          `json:"endpoint"`
	Stream                  *bool           `json:"stream"`
	Model                   string          `json:"model"`
	HTTPStatus              *int            `json:"http_status"`
	RawReason               string          `json:"raw_reason"`
	NormalizedCode          string          `json:"normalized_code"`
	Termination             string          `json:"termination"`
	ResponseProgress        string          `json:"response_progress"`
	ResponseTerminal        string          `json:"response_terminal"`
	ProviderOutcome         string          `json:"provider_outcome"`
	ContentEgressObserved   bool            `json:"content_egress_observed"`
	ClientWriteError        bool            `json:"client_write_error"`
	ResponseEgressCompleted bool            `json:"response_egress_completed"`
	ClientDeparted          bool            `json:"client_departed"`
	EvidenceConflict        bool            `json:"evidence_conflict"`
	AttemptsTruncated       bool            `json:"attempts_truncated"`
	AttemptCount            int             `json:"attempt_count"`
	DispatchedAttemptCount  int             `json:"dispatched_attempt_count"`
	DeadlineRefusalCount    int             `json:"deadline_refusal_count"`
	Attempts                []AttemptRecord `json:"attempts"`
}

// AttemptRecord describes observations, not an inferred engine admission.
// WriteStarted is the writer's dequeue callback, WriteCompleted its successful
// return. A failed write can still have delivered bytes to a provider.
type AttemptRecord struct {
	RequestID            string `json:"request_id"`
	Attempt              int    `json:"attempt"`
	BackupOf             string `json:"backup_of"`
	Winning              bool   `json:"winning"`
	WriteStarted         bool   `json:"write_started"`
	WriteCompleted       bool   `json:"write_completed"`
	ProviderAcknowledged bool   `json:"provider_acknowledged"`
	ContentObserved      bool   `json:"content_observed"`
	ProviderOutcome      string `json:"provider_outcome"`
	RawReason            string `json:"raw_reason"`
	NormalizedCode       string `json:"normalized_code"`
	HTTPStatus           *int   `json:"http_status"`
}

// RequestCode only maps the authoritative final classification. exhausted is
// supplied by the dispatch classifier, not guessed from a provider status.
func RequestCode(reason string, exhausted bool) string {
	switch reason {
	case "first_chunk_timeout":
		return "ext_first_content_timeout"
	case "deadline_unreachable":
		if exhausted {
			return "ext_coordinator_exhausted"
		}
	case "dispatch_exhausted":
		if exhausted {
			return "ext_coordinator_exhausted"
		}
	}
	return ""
}

func AttemptCode(reason string) string {
	if reason == "deadline_unreachable" {
		return "int_provider_deadline_rejected"
	}
	return ""
}
