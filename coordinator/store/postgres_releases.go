package store

import (
	"context"
	"fmt"
	"time"
)

// --- Releases ---

func (s *PostgresStore) SetRelease(release *Release) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO releases (version, platform, backend, binary_hash, bundle_hash, metallib_hash, python_hash, runtime_hash, template_hashes, url, changelog, active, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, TRUE, NOW())
		 ON CONFLICT (version, platform) DO UPDATE SET
		   backend = $3, binary_hash = $4, bundle_hash = $5, metallib_hash = $6, python_hash = $7, runtime_hash = $8, template_hashes = $9, url = $10, changelog = $11, active = TRUE`,
		release.Version, release.Platform, release.Backend, release.BinaryHash, release.BundleHash,
		release.MetallibHash, release.PythonHash, release.RuntimeHash, release.TemplateHashes,
		release.URL, release.Changelog,
	)
	if err != nil {
		return fmt.Errorf("store: set release: %w", err)
	}
	return nil
}

func (s *PostgresStore) ListReleases() []Release {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT version, platform, COALESCE(backend, ''), binary_hash, bundle_hash, COALESCE(metallib_hash, ''),
		        COALESCE(python_hash, ''), COALESCE(runtime_hash, ''), COALESCE(template_hashes, ''),
		        url, changelog, active, created_at
		 FROM releases ORDER BY created_at DESC`,
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var releases []Release
	for rows.Next() {
		var r Release
		if err := rows.Scan(&r.Version, &r.Platform, &r.Backend, &r.BinaryHash, &r.BundleHash, &r.MetallibHash,
			&r.PythonHash, &r.RuntimeHash, &r.TemplateHashes,
			&r.URL, &r.Changelog, &r.Active, &r.CreatedAt); err != nil {
			continue
		}
		releases = append(releases, r)
	}
	return releases
}

func (s *PostgresStore) GetLatestRelease(platform string) *Release {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT version, platform, COALESCE(backend, ''), binary_hash, bundle_hash, COALESCE(metallib_hash, ''),
		        COALESCE(python_hash, ''), COALESCE(runtime_hash, ''), COALESCE(template_hashes, ''),
		        url, changelog, active, created_at
		 FROM releases WHERE platform = $1 AND active = TRUE`, platform,
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var latest *Release
	for rows.Next() {
		var r Release
		if err := rows.Scan(&r.Version, &r.Platform, &r.Backend, &r.BinaryHash, &r.BundleHash, &r.MetallibHash,
			&r.PythonHash, &r.RuntimeHash, &r.TemplateHashes,
			&r.URL, &r.Changelog, &r.Active, &r.CreatedAt); err != nil {
			return nil
		}
		if latest == nil ||
			releaseVersionGreater(r.Version, latest.Version) ||
			(r.Version == latest.Version && r.CreatedAt.After(latest.CreatedAt)) {
			copy := r
			latest = &copy
		}
	}
	if rows.Err() != nil || latest == nil {
		return nil
	}
	return latest
}

func (s *PostgresStore) DeleteRelease(version, platform string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
		`UPDATE releases SET active = FALSE WHERE version = $1 AND platform = $2`,
		version, platform,
	)
	if err != nil {
		return fmt.Errorf("store: delete release: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("release %s/%s not found", version, platform)
	}
	return nil
}
