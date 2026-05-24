package store

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

type scanner interface {
	Scan(dest ...any) error
}

func (s *PostgresStore) UpsertModelRegistryEntry(entry *ModelRegistryEntry) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	runtimeParameters, err := marshalMetadata(entry.RuntimeParameters)
	if err != nil {
		return err
	}
	metadata, err := marshalMetadata(entry.Metadata)
	if err != nil {
		return err
	}
	_, err = s.pool.Exec(ctx, `
		INSERT INTO model_registry (id, display_name, family, architecture, quantization, max_context_length, max_output_length, min_ram_gb, capabilities, status, description, runtime_parameters, metadata, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, COALESCE(NULLIF($14::timestamptz, '0001-01-01 00:00:00+00'::timestamptz), NOW()), NOW())
		ON CONFLICT (id) DO UPDATE SET
		  display_name = $2, family = $3, architecture = $4, quantization = $5, max_context_length = $6,
		  max_output_length = $7, min_ram_gb = $8, capabilities = $9,
		  description = $11, runtime_parameters = $12, metadata = $13, updated_at = NOW()`,
		entry.ID, entry.DisplayName, entry.Family, entry.Architecture, entry.Quantization,
		entry.MaxContextLength, entry.MaxOutputLength, entry.MinRAMGB, entry.Capabilities,
		entry.Status, entry.Description, runtimeParameters, metadata, entry.CreatedAt)
	if err != nil {
		return fmt.Errorf("store: upsert model registry entry: %w", err)
	}
	return nil
}

func (s *PostgresStore) SetModelVersion(entry *ModelRegistryEntry, version *ModelVersion, files []ModelVersionFile) error {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin model version tx: %w", err)
	}
	defer tx.Rollback(ctx)

	entryRuntimeParameters, err := marshalMetadata(entry.RuntimeParameters)
	if err != nil {
		return err
	}
	entryMetadata, err := marshalMetadata(entry.Metadata)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `
		INSERT INTO model_registry (id, display_name, family, architecture, quantization, max_context_length, max_output_length, min_ram_gb, capabilities, status, description, runtime_parameters, metadata, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, NOW(), NOW())
		ON CONFLICT (id) DO UPDATE SET
		  display_name = $2, family = $3, architecture = $4, quantization = $5, max_context_length = $6,
		  max_output_length = $7, min_ram_gb = $8, capabilities = $9,
		  description = $11, runtime_parameters = $12, metadata = $13, updated_at = NOW()`,
		entry.ID, entry.DisplayName, entry.Family, entry.Architecture, entry.Quantization,
		entry.MaxContextLength, entry.MaxOutputLength, entry.MinRAMGB, entry.Capabilities,
		entry.Status, entry.Description, entryRuntimeParameters, entryMetadata)
	if err != nil {
		return fmt.Errorf("store: upsert model in version tx: %w", err)
	}

	versionMetadata, err := marshalMetadata(version.Metadata)
	if err != nil {
		return err
	}
	err = tx.QueryRow(ctx, `
		INSERT INTO model_versions (model_id, version, r2_prefix, aggregate_sha256, total_size_bytes, file_count, status, uploaded_by, uploaded_at, metadata)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW(), $9)
		ON CONFLICT (model_id, version) DO UPDATE SET
		  r2_prefix = $3, aggregate_sha256 = $4, total_size_bytes = $5, file_count = $6,
		  status = $7, uploaded_by = $8, metadata = $9
		RETURNING id, uploaded_at, promoted_at`,
		version.ModelID, version.Version, version.R2Prefix, version.AggregateSHA256,
		version.TotalSizeBytes, version.FileCount, version.Status, version.UploadedBy,
		versionMetadata).Scan(&version.ID, &version.UploadedAt, &version.PromotedAt)
	if err != nil {
		return fmt.Errorf("store: upsert model version: %w", err)
	}

	if _, err := tx.Exec(ctx, `DELETE FROM model_version_files WHERE model_version_id = $1`, version.ID); err != nil {
		return fmt.Errorf("store: replace model version files: %w", err)
	}
	for _, file := range files {
		if _, err := tx.Exec(ctx, `
			INSERT INTO model_version_files (model_version_id, path, size_bytes, sha256, role)
			VALUES ($1, $2, $3, $4, $5)`,
			version.ID, file.Path, file.SizeBytes, file.SHA256, file.Role); err != nil {
			return fmt.Errorf("store: insert model version file %q: %w", file.Path, err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("store: commit model version tx: %w", err)
	}
	return nil
}

func (s *PostgresStore) PromoteModelVersion(modelID, version string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin promote tx: %w", err)
	}
	defer tx.Rollback(ctx)

	var versionID int64
	if err := tx.QueryRow(ctx, `SELECT id FROM model_versions WHERE model_id = $1 AND version = $2`, modelID, version).Scan(&versionID); err != nil {
		if err == pgx.ErrNoRows {
			return fmt.Errorf("model version %q %q not found", modelID, version)
		}
		return fmt.Errorf("store: find model version: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO model_active_versions (model_id, model_version_id, activated_at)
		VALUES ($1, $2, NOW())
		ON CONFLICT (model_id) DO UPDATE SET model_version_id = $2, activated_at = NOW()`, modelID, versionID); err != nil {
		return fmt.Errorf("store: set active model version: %w", err)
	}
	if _, err := tx.Exec(ctx, `UPDATE model_versions SET promoted_at = NOW() WHERE id = $1`, versionID); err != nil {
		return fmt.Errorf("store: mark model version promoted: %w", err)
	}
	return tx.Commit(ctx)
}

func (s *PostgresStore) SetModelStatus(modelID, status string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx, `UPDATE model_registry SET status = $2, updated_at = NOW() WHERE id = $1`, modelID, status)
	if err != nil {
		return fmt.Errorf("store: set model status: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("model %q not found", modelID)
	}
	return nil
}

func (s *PostgresStore) ListActiveModelRegistry() []ModelRegistryRecord {
	records, err := s.ListActiveModelRegistryWithError()
	if err != nil {
		return nil
	}
	return records
}

func (s *PostgresStore) ListActiveModelRegistryWithError() ([]ModelRegistryRecord, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx, activeModelRegistryQuery+` ORDER BY mr.min_ram_gb ASC, mr.id ASC`)
	if err != nil {
		return nil, fmt.Errorf("store: list active model registry: %w", err)
	}
	defer rows.Close()

	var records []ModelRegistryRecord
	for rows.Next() {
		rec, err := scanModelRegistryRecord(rows)
		if err != nil {
			return nil, fmt.Errorf("store: scan active model registry: %w", err)
		}
		if err := s.loadModelRegistryFiles(ctx, rec); err != nil {
			return nil, err
		}
		records = append(records, *rec)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: iterate active model registry: %w", err)
	}
	return records, nil
}

func (s *PostgresStore) GetModelRegistryRecord(modelID string) (*ModelRegistryRecord, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rec, err := scanModelRegistryRecord(s.pool.QueryRow(ctx, activeModelRegistryQuery+` AND mr.id = $1`, modelID))
	if err != nil {
		if err == pgx.ErrNoRows {
			return nil, fmt.Errorf("model %q not found", modelID)
		}
		return nil, fmt.Errorf("store: get model registry record: %w", err)
	}
	if err := s.loadModelRegistryFiles(ctx, rec); err != nil {
		return nil, err
	}
	return rec, nil
}

func (s *PostgresStore) GetModelManifest(modelID string) (*ModelManifest, error) {
	rec, err := s.GetModelRegistryRecord(modelID)
	if err != nil {
		return nil, err
	}
	return manifestFromRecord(rec), nil
}

func (s *PostgresStore) UpsertPublishingAPIKey(key *PublishingAPIKey) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx, `
		INSERT INTO publishing_api_keys (id, name, key_hash, active, created_at, last_used_at)
		VALUES ($1, $2, $3, $4, COALESCE(NULLIF($5::timestamptz, '0001-01-01 00:00:00+00'::timestamptz), NOW()), $6)
		ON CONFLICT (id) DO UPDATE SET name = $2, key_hash = $3, active = $4, last_used_at = $6`,
		key.ID, key.Name, key.KeyHash, key.Active, key.CreatedAt, key.LastUsedAt)
	if err != nil {
		return fmt.Errorf("store: upsert publishing API key: %w", err)
	}
	return nil
}

func (s *PostgresStore) FindPublishingAPIKeys() []PublishingAPIKey {
	keys, err := s.FindPublishingAPIKeysWithError()
	if err != nil {
		return nil
	}
	return keys
}

func (s *PostgresStore) FindPublishingAPIKeysWithError() ([]PublishingAPIKey, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx, `SELECT id, name, key_hash, active, created_at, last_used_at FROM publishing_api_keys ORDER BY created_at ASC`)
	if err != nil {
		return nil, fmt.Errorf("store: find publishing API keys: %w", err)
	}
	defer rows.Close()

	var keys []PublishingAPIKey
	for rows.Next() {
		var key PublishingAPIKey
		if err := rows.Scan(&key.ID, &key.Name, &key.KeyHash, &key.Active, &key.CreatedAt, &key.LastUsedAt); err != nil {
			return nil, fmt.Errorf("store: scan publishing API key: %w", err)
		}
		keys = append(keys, key)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: iterate publishing API keys: %w", err)
	}
	return keys, nil
}

func (s *PostgresStore) MarkPublishingAPIKeyUsed(id string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx, `UPDATE publishing_api_keys SET last_used_at = NOW() WHERE id = $1`, id)
	if err != nil {
		return fmt.Errorf("store: mark publishing API key used: %w", err)
	}
	return nil
}

const activeModelRegistryQuery = `
	SELECT mr.id, mr.display_name, mr.family, mr.architecture, mr.quantization, mr.max_context_length,
	       mr.max_output_length, mr.min_ram_gb, mr.capabilities, mr.status, mr.description,
	       mr.runtime_parameters, mr.metadata, mr.created_at, mr.updated_at,
	       mv.id, mv.model_id, mv.version, mv.r2_prefix, mv.aggregate_sha256,
	       mv.total_size_bytes, mv.file_count, mv.status, mv.uploaded_by,
	       mv.uploaded_at, mv.promoted_at, mv.metadata
	FROM model_registry mr
	JOIN model_active_versions mav ON mav.model_id = mr.id
	JOIN model_versions mv ON mv.id = mav.model_version_id
	WHERE mr.status IN ('active', 'beta') AND mv.status = 'ready'`

func scanModelRegistryRecord(row scanner) (*ModelRegistryRecord, error) {
	var rec ModelRegistryRecord
	var version ModelVersion
	var entryRuntimeParameters, entryMetadata, versionMetadata []byte
	err := row.Scan(
		&rec.ID, &rec.DisplayName, &rec.Family, &rec.Architecture, &rec.Quantization, &rec.MaxContextLength,
		&rec.MaxOutputLength, &rec.MinRAMGB, &rec.Capabilities, &rec.Status, &rec.Description,
		&entryRuntimeParameters, &entryMetadata, &rec.CreatedAt, &rec.UpdatedAt,
		&version.ID, &version.ModelID, &version.Version, &version.R2Prefix, &version.AggregateSHA256,
		&version.TotalSizeBytes, &version.FileCount, &version.Status, &version.UploadedBy,
		&version.UploadedAt, &version.PromotedAt, &versionMetadata,
	)
	if err != nil {
		return nil, err
	}
	rec.RuntimeParameters = unmarshalMetadata(entryRuntimeParameters)
	rec.Metadata = unmarshalMetadata(entryMetadata)
	version.Metadata = unmarshalMetadata(versionMetadata)
	rec.ActiveVersion = &version
	return &rec, nil
}

func (s *PostgresStore) loadModelRegistryFiles(ctx context.Context, rec *ModelRegistryRecord) error {
	if rec == nil || rec.ActiveVersion == nil {
		return nil
	}
	rows, err := s.pool.Query(ctx, `SELECT id, model_version_id, path, size_bytes, sha256, role FROM model_version_files WHERE model_version_id = $1 ORDER BY path ASC`, rec.ActiveVersion.ID)
	if err != nil {
		return fmt.Errorf("store: list model version files: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var file ModelVersionFile
		if err := rows.Scan(&file.ID, &file.ModelVersionID, &file.Path, &file.SizeBytes, &file.SHA256, &file.Role); err != nil {
			return fmt.Errorf("store: scan model version file: %w", err)
		}
		rec.Files = append(rec.Files, file)
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("store: iterate model version files: %w", err)
	}
	if rec.Files == nil {
		rec.Files = []ModelVersionFile{}
	}
	return nil
}

func marshalMetadata(metadata map[string]any) ([]byte, error) {
	if metadata == nil {
		metadata = map[string]any{}
	}
	data, err := json.Marshal(metadata)
	if err != nil {
		return nil, fmt.Errorf("store: marshal metadata: %w", err)
	}
	return data, nil
}

func unmarshalMetadata(data []byte) map[string]any {
	if len(data) == 0 {
		return map[string]any{}
	}
	out := map[string]any{}
	if err := json.Unmarshal(data, &out); err != nil {
		return map[string]any{}
	}
	return out
}
