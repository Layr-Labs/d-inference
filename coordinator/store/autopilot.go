package store

import (
	"context"
	"time"
)

// AutopilotRecord contains control metadata only, never inference content or
// free-form provider errors. Each phase is idempotent for a command identity.
type AutopilotRecord struct {
	Reason     string    `json:"reason,omitempty"`
	Shape      string    `json:"shape,omitempty"`
	CommandID  string    `json:"command_id"`
	At         time.Time `json:"at"`
	ProviderID string    `json:"provider_id"`
	Phase      string    `json:"phase"`
	Load       string    `json:"load,omitempty"`
	Unload     []string  `json:"unload"`
	Before     []string  `json:"before"`
	After      []string  `json:"after"`
	Benefit    float64   `json:"predicted_benefit_seconds"`
	ElapsedMS  int64     `json:"elapsed_ms,omitempty"`
	LoadMS     int64     `json:"load_ms,omitempty"`
	ReleaseMS  int64     `json:"release_ms,omitempty"`
}

type AutopilotStore interface {
	RecordAutopilot(context.Context, []AutopilotRecord) error
	AutopilotRecords(context.Context, time.Time, int) ([]AutopilotRecord, error)
}
