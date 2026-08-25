package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/hardwareadmission"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func (s *PostgresStore) GetActiveHardwareAdmissionPolicy(ctx context.Context) (*hardwareadmission.Policy, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	var policy hardwareadmission.Policy
	err := s.pool.QueryRow(ctx, `
		SELECT p.version, p.mode, p.min_memory_gb, p.min_memory_bandwidth_gbs,
		       p.min_fp16_millitflops, p.catalog_version, p.created_at,
		       p.created_by, p.reason, p.grandfather_cutoff_at,
		       (SELECT COUNT(*) FROM hardware_admissions
		        WHERE source = 'grandfathered' AND revoked_at IS NULL)
		FROM hardware_admission_state s
		JOIN hardware_admission_policies p ON p.version = s.active_policy_version
		WHERE s.singleton = TRUE
	`).Scan(
		&policy.Version, &policy.Mode, &policy.MinMemoryGB, &policy.MinMemoryBandwidthGBs,
		&policy.MinFP16MilliTFLOPS, &policy.CatalogVersion, &policy.CreatedAt,
		&policy.CreatedBy, &policy.Reason, &policy.GrandfatherCutoffAt,
		&policy.GrandfatheredProviderCount,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("store: get active hardware admission policy: %w", err)
	}
	return &policy, nil
}

func (s *PostgresStore) ActivateHardwareAdmissionPolicy(ctx context.Context, policy hardwareadmission.Policy, expectedCurrentVersion int64) (hardwareadmission.Policy, error) {
	if policy.CatalogVersion == "" {
		policy.CatalogVersion = hardwareadmission.CatalogVersion
	}
	if err := policy.Validate(); err != nil {
		return hardwareadmission.Policy{}, err
	}

	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return hardwareadmission.Policy{}, fmt.Errorf("store: begin hardware policy activation: %w", err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()

	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('darkbloom_hardware_admission_policy'))`); err != nil {
		return hardwareadmission.Policy{}, fmt.Errorf("store: lock hardware policy activation: %w", err)
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO hardware_admission_state (singleton) VALUES (TRUE) ON CONFLICT (singleton) DO NOTHING`,
	); err != nil {
		return hardwareadmission.Policy{}, fmt.Errorf("store: initialize hardware policy state: %w", err)
	}
	var activeVersion int64
	if err := tx.QueryRow(ctx, `
		SELECT COALESCE(active_policy_version, 0)
		FROM hardware_admission_state
		WHERE singleton = TRUE
		FOR UPDATE
	`).Scan(&activeVersion); err != nil {
		return hardwareadmission.Policy{}, fmt.Errorf("store: read active hardware policy version: %w", err)
	}
	if activeVersion != expectedCurrentVersion {
		return hardwareadmission.Policy{}, fmt.Errorf(
			"%w: expected %d, active %d",
			ErrHardwareAdmissionPolicyConflict, expectedCurrentVersion, activeVersion)
	}
	var enforceCount int
	if err := tx.QueryRow(ctx,
		`SELECT COUNT(*) FROM hardware_admission_policies WHERE mode = 'enforce'`,
	).Scan(&enforceCount); err != nil {
		return hardwareadmission.Policy{}, fmt.Errorf("store: inspect prior hardware enforcement: %w", err)
	}
	if policy.Mode == hardwareadmission.ModeEnforce && enforceCount == 0 {
		cutoff := time.Now().UTC()
		policy.GrandfatherCutoffAt = &cutoff
	}

	err = tx.QueryRow(ctx, `
		INSERT INTO hardware_admission_policies (
			mode, min_memory_gb, min_memory_bandwidth_gbs, min_fp16_millitflops,
			catalog_version, created_by, reason, grandfather_cutoff_at
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
		RETURNING version, created_at
	`,
		policy.Mode, policy.MinMemoryGB, policy.MinMemoryBandwidthGBs,
		policy.MinFP16MilliTFLOPS, policy.CatalogVersion,
		policy.CreatedBy, policy.Reason, policy.GrandfatherCutoffAt,
	).Scan(&policy.Version, &policy.CreatedAt)
	if err != nil {
		return hardwareadmission.Policy{}, fmt.Errorf("store: insert hardware admission policy: %w", err)
	}

	if policy.GrandfatherCutoffAt != nil {
		tag, err := tx.Exec(ctx, `
			INSERT INTO hardware_admissions (
				serial_number, source, policy_version, hardware, admitted_at
			)
			SELECT DISTINCT ON (UPPER(TRIM(serial_number)))
				UPPER(TRIM(serial_number)), 'grandfathered', $1, hardware, $2
			FROM providers
			WHERE TRIM(serial_number) <> ''
			  AND (trust_level = 'hardware' OR mda_verified = TRUE)
			ORDER BY UPPER(TRIM(serial_number)), last_seen DESC
			ON CONFLICT (serial_number) DO NOTHING
		`, policy.Version, *policy.GrandfatherCutoffAt)
		if err != nil {
			return hardwareadmission.Policy{}, fmt.Errorf("store: grandfather existing providers: %w", err)
		}
		policy.GrandfatheredProviderCount = int(tag.RowsAffected())
	}

	if _, err := tx.Exec(ctx, `
		INSERT INTO hardware_admission_state (singleton, active_policy_version)
		VALUES (TRUE, $1)
		ON CONFLICT (singleton) DO UPDATE SET active_policy_version = EXCLUDED.active_policy_version
	`, policy.Version); err != nil {
		return hardwareadmission.Policy{}, fmt.Errorf("store: activate hardware admission policy: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return hardwareadmission.Policy{}, fmt.Errorf("store: commit hardware policy activation: %w", err)
	}
	return policy, nil
}

func (s *PostgresStore) IsHardwareAdmitted(ctx context.Context, serialNumber string) (bool, error) {
	serial := normalizeHardwareSerial(serialNumber)
	if serial == "" {
		return false, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	var admitted bool
	if err := s.pool.QueryRow(ctx,
		`SELECT EXISTS (
			SELECT 1 FROM hardware_admissions
			WHERE serial_number = $1 AND revoked_at IS NULL
		)`,
		serial,
	).Scan(&admitted); err != nil {
		return false, fmt.Errorf("store: check hardware admission: %w", err)
	}
	return admitted, nil
}

func (s *PostgresStore) AdmitHardware(ctx context.Context, admission HardwareAdmission) error {
	serial := normalizeHardwareSerial(admission.SerialNumber)
	if serial == "" {
		return fmt.Errorf("store: hardware admission serial is required")
	}
	if admission.Source == "" {
		admission.Source = "policy"
	}
	if admission.AdmittedAt.IsZero() {
		admission.AdmittedAt = time.Now().UTC()
	}
	hardwareJSON, err := json.Marshal(admission.Hardware)
	if err != nil {
		return fmt.Errorf("store: marshal admitted hardware: %w", err)
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	tag, err := s.pool.Exec(ctx, `
		INSERT INTO hardware_admissions (
			serial_number, source, policy_version, hardware, admitted_at
		) VALUES ($1,$2,$3,$4,$5)
		ON CONFLICT (serial_number) DO NOTHING
	`, serial, admission.Source, admission.PolicyVersion, hardwareJSON, admission.AdmittedAt)
	if err != nil {
		return fmt.Errorf("store: admit hardware: %w", err)
	}
	if tag.RowsAffected() == 0 {
		var revoked bool
		if err := s.pool.QueryRow(ctx, `
			SELECT revoked_at IS NOT NULL
			FROM hardware_admissions WHERE serial_number = $1
		`, serial).Scan(&revoked); err != nil {
			return fmt.Errorf("store: inspect existing hardware admission: %w", err)
		}
		if revoked {
			return fmt.Errorf("%w: %s", ErrHardwareAdmissionRevoked, serial)
		}
	}
	return nil
}

func (s *PostgresStore) ListHardwareAdmissions(ctx context.Context, limit int) ([]HardwareAdmission, error) {
	if limit <= 0 || limit > 1000 {
		limit = 500
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	rows, err := s.pool.Query(ctx, `
		SELECT serial_number, source, policy_version, hardware, admitted_at,
		       revoked_at, revoked_by, revocation_reason
		FROM hardware_admissions
		ORDER BY admitted_at DESC
		LIMIT $1
	`, limit)
	if err != nil {
		return nil, fmt.Errorf("store: list hardware admissions: %w", err)
	}
	defer rows.Close()
	out := make([]HardwareAdmission, 0, limit)
	for rows.Next() {
		var admission HardwareAdmission
		var hardwareJSON []byte
		if err := rows.Scan(
			&admission.SerialNumber, &admission.Source, &admission.PolicyVersion,
			&hardwareJSON, &admission.AdmittedAt, &admission.RevokedAt,
			&admission.RevokedBy, &admission.RevocationReason,
		); err != nil {
			return nil, fmt.Errorf("store: scan hardware admission: %w", err)
		}
		if err := json.Unmarshal(hardwareJSON, &admission.Hardware); err != nil {
			return nil, fmt.Errorf("store: decode admitted hardware: %w", err)
		}
		out = append(out, admission)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: list hardware admissions rows: %w", err)
	}
	return out, nil
}

func (s *PostgresStore) RevokeHardwareAdmission(
	ctx context.Context,
	serialNumber, actor, reason string,
) error {
	return s.setHardwareAdmissionRevocation(ctx, serialNumber, actor, reason, true)
}

func (s *PostgresStore) RestoreHardwareAdmission(
	ctx context.Context,
	serialNumber, actor, reason string,
) error {
	return s.setHardwareAdmissionRevocation(ctx, serialNumber, actor, reason, false)
}

func (s *PostgresStore) setHardwareAdmissionRevocation(
	ctx context.Context,
	serialNumber, actor, reason string,
	revoke bool,
) error {
	serial := normalizeHardwareSerial(serialNumber)
	if serial == "" || actor == "" || reason == "" {
		return fmt.Errorf("store: serial, actor, and reason are required")
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin hardware revocation: %w", err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	var tag pgconn.CommandTag
	action := "restored"
	if revoke {
		action = "revoked"
		tag, err = tx.Exec(ctx, `
			UPDATE hardware_admissions
			SET revoked_at = NOW(), revoked_by = $2, revocation_reason = $3
			WHERE serial_number = $1 AND revoked_at IS NULL
		`, serial, actor, reason)
	} else {
		tag, err = tx.Exec(ctx, `
			UPDATE hardware_admissions
			SET revoked_at = NULL, revoked_by = '', revocation_reason = ''
			WHERE serial_number = $1 AND revoked_at IS NOT NULL
		`, serial)
	}
	if err != nil {
		return fmt.Errorf("store: %s hardware admission: %w", action, err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("%w: hardware admission %s", ErrNotFound, serial)
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO hardware_admission_events (serial_number, action, actor, reason)
		VALUES ($1,$2,$3,$4)
	`, serial, action, actor, reason); err != nil {
		return fmt.Errorf("store: audit hardware admission %s: %w", action, err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("store: commit hardware admission %s: %w", action, err)
	}
	return nil
}

func (s *PostgresStore) RecordHardwareAdmissionAttempt(ctx context.Context, attempt HardwareAdmissionAttempt) error {
	if attempt.CreatedAt.IsZero() {
		attempt.CreatedAt = time.Now().UTC()
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	_, err := s.pool.Exec(ctx, `
		INSERT INTO hardware_admission_attempts (
			provider_id, serial_number, account_id, policy_version, mode,
			decision, reason_code, hardware, failed_checks, created_at
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
	`,
		attempt.ProviderID, normalizeHardwareSerial(attempt.SerialNumber), attempt.AccountID,
		attempt.PolicyVersion, attempt.Mode, attempt.Decision, attempt.ReasonCode,
		attempt.hardwareJSON(), attempt.failedChecksJSON(), attempt.CreatedAt,
	)
	if err != nil {
		return fmt.Errorf("store: record hardware admission attempt: %w", err)
	}
	return nil
}

func (s *PostgresStore) ListHardwareAdmissionAttempts(ctx context.Context, accountID string, limit int) ([]HardwareAdmissionAttempt, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	query := `
		SELECT id, provider_id, serial_number, account_id, policy_version, mode,
		       decision, reason_code, hardware, failed_checks, created_at
		FROM hardware_admission_attempts
	`
	args := []any{}
	if accountID != "" {
		query += ` WHERE account_id = $1 ORDER BY created_at DESC LIMIT $2`
		args = append(args, accountID, limit)
	} else {
		query += ` ORDER BY created_at DESC LIMIT $1`
		args = append(args, limit)
	}
	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("store: list hardware admission attempts: %w", err)
	}
	defer rows.Close()

	out := make([]HardwareAdmissionAttempt, 0, limit)
	for rows.Next() {
		var attempt HardwareAdmissionAttempt
		var hardwareJSON, failedJSON []byte
		if err := rows.Scan(
			&attempt.ID, &attempt.ProviderID, &attempt.SerialNumber, &attempt.AccountID,
			&attempt.PolicyVersion, &attempt.Mode, &attempt.Decision, &attempt.ReasonCode,
			&hardwareJSON, &failedJSON, &attempt.CreatedAt,
		); err != nil {
			return nil, fmt.Errorf("store: scan hardware admission attempt: %w", err)
		}
		if err := json.Unmarshal(hardwareJSON, &attempt.Hardware); err != nil {
			return nil, fmt.Errorf("store: decode attempted hardware: %w", err)
		}
		if err := json.Unmarshal(failedJSON, &attempt.FailedChecks); err != nil {
			return nil, fmt.Errorf("store: decode hardware admission failures: %w", err)
		}
		out = append(out, attempt)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: list hardware admission attempts rows: %w", err)
	}
	return out, nil
}
