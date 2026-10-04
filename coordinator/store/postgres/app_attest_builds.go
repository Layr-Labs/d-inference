package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/shared"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
)

const appAttestBuildDDL = `CREATE TABLE IF NOT EXISTS app_attest_build_qualifications (
 binary_hash TEXT PRIMARY KEY CHECK (binary_hash ~ '^[0-9a-f]{64}$'),
 record JSONB NOT NULL
)`

func (s *PostgresStore) ListAppAttestBuildQualifications(ctx context.Context) ([]store.AppAttestBuildQualification, error) {
	rows, err := s.pool.Query(ctx, `SELECT record FROM app_attest_build_qualifications`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []store.AppAttestBuildQualification{}
	for rows.Next() {
		var q store.AppAttestBuildQualification
		if err := rows.Scan(&q); err != nil {
			return nil, err
		}
		out = append(out, q)
	}
	return out, rows.Err()
}

func (s *PostgresStore) QualifyAppAttestBuild(ctx context.Context, q store.AppAttestBuildQualification) (bool, error) {
	if err := q.ValidateApproval(); err != nil {
		return false, err
	}
	q.ApprovedAt = time.Now().UTC()
	raw, err := json.Marshal(q)
	if err != nil {
		return false, err
	}
	result, err := s.pool.Exec(ctx, `INSERT INTO app_attest_build_qualifications(binary_hash, record)
 VALUES ($1,$2) ON CONFLICT DO NOTHING`, q.Release.BinaryHash, raw)
	if err != nil {
		return false, err
	}
	if result.RowsAffected() == 1 {
		return true, nil
	}
	var old store.AppAttestBuildQualification
	if err := s.pool.QueryRow(ctx, `SELECT record FROM app_attest_build_qualifications WHERE binary_hash=$1`, q.Release.BinaryHash).Scan(&old); err != nil {
		return false, err
	}
	if !old.RevokedAt.IsZero() || !old.Matches(q.AppAttestBuildIdentity) {
		return false, store.ErrBuildConflict
	}
	return false, nil
}

func (s *PostgresStore) RevokeAppAttestBuild(ctx context.Context, binary, actor, reason string) (bool, error) {
	if err := shared.ValidateBuildRevocation(binary, actor, reason); err != nil {
		return false, err
	}
	q := store.AppAttestBuildQualification{AppAttestBuildIdentity: store.AppAttestBuildIdentity{Release: store.Release{BinaryHash: binary}},
		RevokedAt: time.Now().UTC(), RevokedBy: actor, RevocationReason: reason}
	raw, err := json.Marshal(q)
	if err != nil {
		return false, err
	}
	// Preserve the original approval/evidence and first revocation audit. A
	// tombstone can fence a legacy env-only build before it has a durable approval.
	result, err := s.pool.Exec(ctx, `INSERT INTO app_attest_build_qualifications(binary_hash, record)
 VALUES ($1,$2::jsonb) ON CONFLICT(binary_hash) DO UPDATE SET record = app_attest_build_qualifications.record ||
 jsonb_build_object('revoked_at', $2::jsonb->'revoked_at', 'revoked_by', $2::jsonb->'revoked_by',
 'revocation_reason', $2::jsonb->'revocation_reason')
 WHERE COALESCE(app_attest_build_qualifications.record->>'revoked_by','') = ''`, binary, raw)
	return result.RowsAffected() == 1, err
}

func (s *PostgresStore) SetQualifiedRelease(ctx context.Context, b store.AppAttestBuildIdentity) error {
	if err := b.Validate(); err != nil {
		return err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(context.Background())
	var q store.AppAttestBuildQualification
	err = tx.QueryRow(ctx, `SELECT record FROM app_attest_build_qualifications WHERE binary_hash=$1 FOR UPDATE`, b.Release.BinaryHash).Scan(&q)
	if errors.Is(err, pgx.ErrNoRows) {
		return store.ErrBuildNotQualified
	}
	if err != nil {
		return err
	}
	if !q.RevokedAt.IsZero() || !q.Matches(b) {
		return store.ErrBuildNotQualified
	}
	r := b.Release
	result, err := tx.Exec(ctx, `INSERT INTO releases
 (version,platform,backend,binary_hash,bundle_hash,metallib_hash,python_hash,runtime_hash,template_hashes,url,changelog,active,created_at)
 VALUES ($1,$2,$3,$4,$5,$6,'','','',$7,$8,TRUE,NOW())
 ON CONFLICT(version,platform) DO UPDATE SET active=TRUE, changelog=EXCLUDED.changelog
 WHERE releases.binary_hash=EXCLUDED.binary_hash AND releases.bundle_hash=EXCLUDED.bundle_hash
 AND releases.metallib_hash=EXCLUDED.metallib_hash AND releases.backend=EXCLUDED.backend
 AND releases.url=EXCLUDED.url AND COALESCE(releases.python_hash,'')=''
 AND COALESCE(releases.runtime_hash,'')='' AND COALESCE(releases.template_hashes,'')=''`,
		r.Version, r.Platform, r.Backend, r.BinaryHash, r.BundleHash, r.MetallibHash, r.URL, r.Changelog)
	if err != nil {
		return err
	}
	if result.RowsAffected() != 1 {
		return store.ErrBuildConflict
	}
	return tx.Commit(ctx)
}
