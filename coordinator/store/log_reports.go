package store

import "time"

// LogReportStore covers provider-submitted log reports.
type LogReportStore interface {
	// StoreLogReport stores a provider log report.
	StoreLogReport(serialNumber, providerID, accountID string, logData []byte) error

	// GetLogReports retrieves log reports for a serial number, newest first.
	GetLogReports(serialNumber string, limit int) ([]LogReport, error)

	// GetLogReport retrieves a single log report by ID.
	GetLogReport(id int64) (*LogReport, error)
}

// LogReport represents a stored provider log report. LogData is only populated
// when fetching a single report by ID (GetLogReport), not when listing.
type LogReport struct {
	ID           int64     `json:"id"`
	SerialNumber string    `json:"serial_number"`
	ProviderID   string    `json:"provider_id"`
	AccountID    string    `json:"account_id"`
	LogSizeBytes int64     `json:"log_size_bytes"`
	CreatedAt    time.Time `json:"created_at"`
	LogData      []byte    `json:"log_data,omitempty"`
}
