package store

import (
	"context"
	"encoding/json"
	"fmt"
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

func validateAutopilotRecord(r AutopilotRecord) error {
	if r.CommandID == "" || len(r.CommandID) > 64 || r.At.IsZero() || len(r.ProviderID) > 128 || len(r.Load) > 256 || len(r.Before) > 32 || len(r.After) > 32 || len(r.Unload) > 32 {
		return fmt.Errorf("invalid autopilot record")
	}
	if len(r.Shape) > 64 {
		return fmt.Errorf("invalid shape")
	}
	switch r.Reason {
	case "", "demand", "bootstrap", "protected_floor", "idle_surplus":
	default:
		return fmt.Errorf("invalid reason")
	}
	switch r.Phase {
	case "proposed", "reserved", "started", "succeeded", "failed", "uncertain":
	default:
		return fmt.Errorf("invalid autopilot phase")
	}
	for _, set := range [][]string{r.Before, r.After, r.Unload} {
		for _, id := range set {
			if len(id) > 256 {
				return fmt.Errorf("invalid model ID")
			}
		}
	}
	_, err := json.Marshal(r)
	return err
}
