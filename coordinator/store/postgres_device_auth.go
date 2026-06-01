package store

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// --- Device Authorization ---

func (s *PostgresStore) CreateDeviceCode(dc *DeviceCode) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO device_codes (device_code, user_code, account_id, status, expires_at)
		 VALUES ($1, $2, $3, $4, $5)`,
		dc.DeviceCode, dc.UserCode, dc.AccountID, dc.Status, dc.ExpiresAt,
	)
	if err != nil {
		return fmt.Errorf("store: create device code: %w", err)
	}
	return nil
}

func (s *PostgresStore) GetDeviceCode(deviceCode string) (*DeviceCode, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var dc DeviceCode
	err := s.pool.QueryRow(ctx,
		`SELECT device_code, user_code, account_id, status, expires_at, created_at
		 FROM device_codes WHERE device_code = $1`, deviceCode,
	).Scan(&dc.DeviceCode, &dc.UserCode, &dc.AccountID, &dc.Status, &dc.ExpiresAt, &dc.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("store: device code not found: %w", err)
	}
	return &dc, nil
}

func (s *PostgresStore) GetDeviceCodeByUserCode(userCode string) (*DeviceCode, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var dc DeviceCode
	err := s.pool.QueryRow(ctx,
		`SELECT device_code, user_code, account_id, status, expires_at, created_at
		 FROM device_codes WHERE user_code = $1`, userCode,
	).Scan(&dc.DeviceCode, &dc.UserCode, &dc.AccountID, &dc.Status, &dc.ExpiresAt, &dc.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("store: user code not found: %w", err)
	}
	return &dc, nil
}

func (s *PostgresStore) ApproveDeviceCode(deviceCode, accountID string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
		`UPDATE device_codes SET status = 'approved', account_id = $2
		 WHERE device_code = $1 AND status = 'pending' AND expires_at > NOW()`,
		deviceCode, accountID,
	)
	if err != nil {
		return fmt.Errorf("store: approve device code: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return errors.New("device code not found, not pending, or expired")
	}
	return nil
}

func (s *PostgresStore) DeleteExpiredDeviceCodes() error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx, `DELETE FROM device_codes WHERE expires_at < NOW()`)
	if err != nil {
		return fmt.Errorf("store: delete expired device codes: %w", err)
	}
	return nil
}
