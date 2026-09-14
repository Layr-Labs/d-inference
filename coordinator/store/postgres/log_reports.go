package postgres

import (
	"context"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/recordutil"
)

func (s *Store) StoreLogReport(accountID string, logData []byte) (int64, error) {
	if len(logData) > recordutil.MaxLogReportSize {
		logData = logData[:recordutil.MaxLogReportSize]
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

func (s *Store) GetLogReport(id int64) (*contracts.LogReport, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	var r contracts.LogReport
	err := s.pool.QueryRow(ctx,
		`SELECT id, account_id, log_data, log_size_bytes, created_at
		 FROM provider_log_reports WHERE id = $1`, id,
	).Scan(&r.ID, &r.AccountID, &r.LogData, &r.LogSizeBytes, &r.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("store: log report %d not found: %w", id, err)
	}
	return &r, nil
}
