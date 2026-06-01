package store

import (
	"encoding/json"
	"time"
)

// Telemetry events are forwarded to Datadog (Logs API + DogStatsD) for durable
// storage and querying, so there are no Store methods for them — only the
// persistence-layer record type below.

// TelemetryEventRecord is the persistence-layer representation of a telemetry
// event. It mirrors protocol.TelemetryEvent but lives in this package so the
// store can stay free of protocol-layer dependencies.
type TelemetryEventRecord struct {
	ID         string          `json:"id"`
	Timestamp  time.Time       `json:"timestamp"`
	Source     string          `json:"source"`
	Severity   string          `json:"severity"`
	Kind       string          `json:"kind"`
	Version    string          `json:"version,omitempty"`
	MachineID  string          `json:"machine_id,omitempty"`
	AccountID  string          `json:"account_id,omitempty"`
	RequestID  string          `json:"request_id,omitempty"`
	SessionID  string          `json:"session_id,omitempty"`
	Message    string          `json:"message"`
	Fields     json.RawMessage `json:"fields,omitempty"`
	Stack      string          `json:"stack,omitempty"`
	ReceivedAt time.Time       `json:"received_at"`
}
