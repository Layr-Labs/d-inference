package store

import (
	"context"
	"fmt"
	"time"
)

// --- Provider Log Reports ---

const maxLogReportSize = 10 << 20 // 10 MB

func (s *PostgresStore) StoreLogReport(serialNumber, providerID, accountID string, logData []byte) error {
	if len(logData) > maxLogReportSize {
		logData = logData[:maxLogReportSize]
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO provider_log_reports (serial_number, provider_id, account_id, log_data, log_size_bytes)
		 VALUES ($1, $2, $3, $4, $5)`,
		serialNumber, providerID, accountID, logData, int64(len(logData)),
	)
	if err != nil {
		return fmt.Errorf("store: insert log report: %w", err)
	}
	return nil
}

func (s *PostgresStore) GetLogReports(serialNumber string, limit int) ([]LogReport, error) {
	if limit <= 0 || limit > 100 {
		limit = 10
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT id, serial_number, provider_id, account_id, log_size_bytes, created_at
		 FROM provider_log_reports
		 WHERE serial_number = $1
		 ORDER BY created_at DESC
		 LIMIT $2`,
		serialNumber, limit,
	)
	if err != nil {
		return nil, fmt.Errorf("store: list log reports: %w", err)
	}
	defer rows.Close()

	var reports []LogReport
	for rows.Next() {
		var r LogReport
		if err := rows.Scan(&r.ID, &r.SerialNumber, &r.ProviderID, &r.AccountID, &r.LogSizeBytes, &r.CreatedAt); err != nil {
			continue
		}
		reports = append(reports, r)
	}
	if reports == nil {
		return []LogReport{}, nil
	}
	return reports, nil
}

func (s *PostgresStore) GetLogReport(id int64) (*LogReport, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	var r LogReport
	err := s.pool.QueryRow(ctx,
		`SELECT id, serial_number, provider_id, account_id, log_data, log_size_bytes, created_at
		 FROM provider_log_reports WHERE id = $1`, id,
	).Scan(&r.ID, &r.SerialNumber, &r.ProviderID, &r.AccountID, &r.LogData, &r.LogSizeBytes, &r.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("store: log report %d not found: %w", id, err)
	}
	return &r, nil
}
