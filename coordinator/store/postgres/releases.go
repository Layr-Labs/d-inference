package postgres

import (
	"context"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/shared"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *PostgresStore) SetRelease(release *store.Release) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO releases (version, platform, backend, binary_hash, bundle_hash, metallib_hash, python_hash, runtime_hash, template_hashes, url, changelog, active, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, TRUE, NOW())
		 ON CONFLICT (version, platform) DO UPDATE SET
		   backend = $3, binary_hash = $4, bundle_hash = $5, metallib_hash = $6, python_hash = $7, runtime_hash = $8, template_hashes = $9, url = $10, changelog = $11, active = TRUE`,
		release.Version, release.Platform, release.Backend, release.BinaryHash, release.BundleHash,
		release.MetallibHash, "", "", release.TemplateHashes, // retired python_hash, runtime_hash columns
		release.URL, release.Changelog,
	)
	if err != nil {
		return fmt.Errorf("store: set release: %w", err)
	}
	return nil
}

func (s *PostgresStore) ListReleases() []store.Release {
	releases, _ := s.ListReleasesWithError()
	return releases
}

func (s *PostgresStore) ListReleasesWithError() ([]store.Release, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT version, platform, COALESCE(backend, ''), binary_hash, bundle_hash, COALESCE(metallib_hash, ''),
		        COALESCE(template_hashes, ''),
		        url, changelog, active, created_at
		 FROM releases ORDER BY created_at DESC`,
	)
	if err != nil {
		return nil, fmt.Errorf("store: list releases: %w", err)
	}
	defer rows.Close()

	var releases []store.Release
	for rows.Next() {
		var r store.Release
		if err := rows.Scan(&r.Version, &r.Platform, &r.Backend, &r.BinaryHash, &r.BundleHash, &r.MetallibHash,
			&r.TemplateHashes,
			&r.URL, &r.Changelog, &r.Active, &r.CreatedAt); err != nil {
			return nil, fmt.Errorf("store: scan release: %w", err)
		}
		releases = append(releases, r)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: iterate releases: %w", err)
	}
	return releases, nil
}

func (s *PostgresStore) GetLatestRelease(platform string) *store.Release {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT version, platform, COALESCE(backend, ''), binary_hash, bundle_hash, COALESCE(metallib_hash, ''),
		        COALESCE(template_hashes, ''),
		        url, changelog, active, created_at
		 FROM releases WHERE platform = $1 AND active = TRUE`, platform,
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var latest *store.Release
	for rows.Next() {
		var r store.Release
		if err := rows.Scan(&r.Version, &r.Platform, &r.Backend, &r.BinaryHash, &r.BundleHash, &r.MetallibHash,
			&r.TemplateHashes,
			&r.URL, &r.Changelog, &r.Active, &r.CreatedAt); err != nil {
			return nil
		}
		if latest == nil ||
			shared.ReleaseVersionGreater(r.Version, latest.Version) ||
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
