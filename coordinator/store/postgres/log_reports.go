package postgres

import (
	"context"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

const maxLogReportSize = 10 << 20

func (s *PostgresStore) StoreLogReport(accountID string, logData []byte) (int64, error) {
	if len(logData) > maxLogReportSize {
		logData = logData[:maxLogReportSize]
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	var reportID int64
	err := s.pool.QueryRow(ctx,
		`INSERT INTO provider_log_reports (account_id, log_data, log_size_bytes)
		 VALUES ($1, $2, $3)
		 RETURNING id`,
		accountID, logData, int64(len(logData)),
	).Scan(&reportID)
	if err != nil {
		return 0, fmt.Errorf("store: insert log report: %w", err)
	}
	return reportID, nil
}

func (s *PostgresStore) GetLogReport(id int64) (*store.LogReport, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	var r store.LogReport
	err := s.pool.QueryRow(ctx,
		`SELECT id, account_id, log_data, log_size_bytes, created_at
		 FROM provider_log_reports WHERE id = $1`, id,
	).Scan(&r.ID, &r.AccountID, &r.LogData, &r.LogSizeBytes, &r.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("store: log report %d not found: %w", id, err)
	}
	return &r, nil
}
