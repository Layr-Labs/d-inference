package contracts

import (
	"time"
)

// LogReport represents a stored provider log report retrieved by its opaque
// support ID.
type LogReport struct {
	ID           int64     `json:"id"`
	AccountID    string    `json:"account_id"`
	LogSizeBytes int64     `json:"log_size_bytes"`
	CreatedAt    time.Time `json:"created_at"`
	LogData      []byte    `json:"log_data,omitempty"`
}

// LogReportStore stores provider support reports.
type LogReportStore interface {
	// --- Provider Log Reports ---

	// StoreLogReport stores a provider log report and returns its support ID.
	StoreLogReport(accountID string, logData []byte) (int64, error)

	// GetLogReport retrieves a single log report by ID.
	GetLogReport(id int64) (*LogReport, error)
}
