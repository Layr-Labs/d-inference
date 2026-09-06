package store

import (
	"context"
	"errors"
	"time"
)

const RequestOutcomeSchemaVersion = 1
const MaxRequestOutcomeAttempts = 128

// RequestOutcomeRecord is an unsampled, prompt-free observation of one incoming
// HTTP request. ReceivedAt defines cohort membership; revisions enrich the same
// request with late provider evidence. No field establishes upstream receipt.
type RequestOutcomeRecord struct {
	CoordRequestID          string                  `json:"coord_request_id"`
	SchemaVersion           int                     `json:"schema_version"`
	Revision                int64                   `json:"revision"`
	ReceivedAt              time.Time               `json:"received_at"`
	UpdatedAt               time.Time               `json:"updated_at"`
	HandlerFinishedAt       *time.Time              `json:"handler_finished_at,omitempty"`
	FinalizedAt             *time.Time              `json:"finalized_at,omitempty"`
	Endpoint                string                  `json:"endpoint"`
	Model                   string                  `json:"model"`
	Stream                  *bool                   `json:"stream,omitempty"`
	HTTPStatus              int                     `json:"http_status"`
	Termination             string                  `json:"termination"`
	ResponseProgress        string                  `json:"response_progress"`
	ProviderOutcome         string                  `json:"provider_outcome"`
	RawStage                string                  `json:"raw_stage"`
	RawReason               string                  `json:"raw_reason"`
	NormalizedCode          string                  `json:"normalized_code"`
	CoordinatorExhausted    bool                    `json:"coordinator_exhausted"`
	ProviderContentObserved bool                    `json:"provider_content_observed"`
	ContentWriteCompleted   bool                    `json:"content_write_completed"`
	EgressCompleted         bool                    `json:"egress_completed"`
	ClientDeparted          bool                    `json:"client_departed"`
	ClientWriteError        bool                    `json:"client_write_error"`
	EgressError             bool                    `json:"egress_error"`
	EvidenceConflict        bool                    `json:"evidence_conflict"`
	AttemptsComplete        bool                    `json:"attempts_complete"`
	AttemptsTruncated       bool                    `json:"attempts_truncated"`
	AttemptsTotal           int                     `json:"attempts_total"`
	Attempts                []RequestAttemptOutcome `json:"attempts"`
}

// RequestAttemptOutcome uses the same stable key as routes/profiles. A submitted
// but incomplete socket write has ambiguous provider receipt, not proof of no
// dispatch. Provider acknowledgments do not prove engine admission.
type RequestAttemptOutcome struct {
	RequestID                string `json:"request_id"`
	Attempt                  int    `json:"attempt"`
	BackupOf                 string `json:"backup_of,omitempty"`
	Winning                  bool   `json:"winning"`
	WriteSubmitted           bool   `json:"write_submitted"`
	WriteCompleted           bool   `json:"write_completed"`
	ProviderAccepted         bool   `json:"provider_accepted"`
	ProviderCompleteObserved bool   `json:"provider_complete_observed"`
	ProviderContentObserved  bool   `json:"provider_content_observed"`
	ProviderOutcome          string `json:"provider_outcome"`
	FinalStatus              string `json:"final_status"`
	RawReason                string `json:"raw_reason"`
	TerminalCause            string `json:"terminal_cause"`
	NormalizedCode           string `json:"normalized_code"`
	Finalized                bool   `json:"finalized"`
}

type RequestOutcomeStore interface {
	RecordRequestOutcomes(context.Context, []RequestOutcomeRecord) error
	// RequestOutcomes returns a bounded received-at cohort [since, until).
	// A full limit does not mean the cohort is complete; narrow the window.
	RequestOutcomes(context.Context, time.Time, time.Time, int) ([]RequestOutcomeRecord, error)
}

func validateRequestOutcome(r RequestOutcomeRecord) error {
	if r.CoordRequestID == "" || len(r.CoordRequestID) > 64 || r.SchemaVersion != RequestOutcomeSchemaVersion || r.Revision < 1 || r.ReceivedAt.IsZero() || r.UpdatedAt.IsZero() {
		return errors.New("store: invalid request outcome identity/version")
	}
	if len(r.Termination) > 64 || len(r.ResponseProgress) > 64 || len(r.ProviderOutcome) > 64 {
		return errors.New("store: oversized request outcome classification")
	}
	if len(r.Attempts) > MaxRequestOutcomeAttempts || len(r.Model) > 256 || len(r.Endpoint) > 64 || len(r.RawReason) > 96 || len(r.RawStage) > 64 || len(r.NormalizedCode) > 128 {
		return errors.New("store: oversized request outcome")
	}
	for _, a := range r.Attempts {
		if a.RequestID == "" || len(a.RequestID) > 64 || len(a.BackupOf) > 64 || len(a.RawReason) > 96 || len(a.TerminalCause) > 96 || len(a.ProviderOutcome) > 64 || len(a.FinalStatus) > 64 || len(a.NormalizedCode) > 128 {
			return errors.New("store: invalid request attempt outcome")
		}
	}
	return nil
}
