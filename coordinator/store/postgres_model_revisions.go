package store

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// The registry row is locked by SetModelVersion's upsert, serializing writers
// for a model before inspecting or replacing its manifest rows.
func checkImmutableModelFiles(ctx context.Context, tx pgx.Tx, modelID, version string, files []ModelVersionFile) error {
	var versionID int64
	err := tx.QueryRow(ctx, `SELECT id FROM model_versions WHERE model_id=$1 AND version=$2`, modelID, version).Scan(&versionID)
	if err == pgx.ErrNoRows {
		return nil
	}
	if err != nil {
		return err
	}
	rows, err := tx.Query(ctx, `SELECT path, size_bytes, sha256, role FROM model_version_files WHERE model_version_id=$1`, versionID)
	if err != nil {
		return err
	}
	defer rows.Close()
	var previous []ModelVersionFile
	for rows.Next() {
		var f ModelVersionFile
		if err := rows.Scan(&f.Path, &f.SizeBytes, &f.SHA256, &f.Role); err != nil {
			return err
		}
		previous = append(previous, f)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if !sameModelVersionFiles(previous, files) {
		return ErrModelVersionImmutable
	}
	return nil
}

// RetireModelVersion withdraws an old revision from routing and attestation.
// The currently desired revision cannot be retired; promote its replacement
// first. This is an explicit operator action, never automatic rollout cleanup.
func (s *PostgresStore) RetireModelVersion(modelID, version string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var id string
	if err := tx.QueryRow(ctx, `SELECT id FROM model_registry WHERE id=$1 FOR UPDATE`, modelID).Scan(&id); err != nil {
		if err == pgx.ErrNoRows {
			return fmt.Errorf("model %q: %w", modelID, ErrNotFound)
		}
		return err
	}
	var versionID int64
	var active bool
	err = tx.QueryRow(ctx, `SELECT mv.id, EXISTS (SELECT 1 FROM model_active_versions a WHERE a.model_version_id=mv.id) FROM model_versions mv WHERE mv.model_id=$1 AND mv.version=$2`, modelID, version).Scan(&versionID, &active)
	if err == pgx.ErrNoRows {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if active {
		return ErrActiveModelVersion
	}
	if _, err := tx.Exec(ctx, `UPDATE model_versions SET status='retired' WHERE id=$1`, versionID); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
