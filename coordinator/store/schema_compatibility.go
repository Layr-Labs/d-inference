package store

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

type schemaQueryer interface {
	Query(context.Context, string, ...any) (pgx.Rows, error)
	QueryRow(context.Context, string, ...any) pgx.Row
}

func checkSchemaCompatibility(ctx context.Context, queryer schemaQueryer) error {
	migrations, err := loadMigrations()
	if err != nil {
		return err
	}
	applied, metadataExists, err := readAppliedMigrations(ctx, queryer)
	if err != nil {
		return err
	}
	if !metadataExists {
		return fmt.Errorf(
			"store: database schema is unversioned; run coordinator-migrate before starting the coordinator",
		)
	}

	current := currentSchemaVersion(applied)
	if current < MinimumSupportedSchemaVersion || current > MaximumSupportedSchemaVersion {
		return fmt.Errorf(
			"store: database schema version %d is outside this binary's supported range [%d, %d]; run the matching coordinator-migrate",
			current,
			MinimumSupportedSchemaVersion,
			MaximumSupportedSchemaVersion,
		)
	}
	if err := validateAppliedMigrations(applied, migrations); err != nil {
		return err
	}
	if err := validateCriticalSchemaShape(ctx, queryer, current); err != nil {
		return fmt.Errorf("store: refusing to serve: %w", err)
	}
	return nil
}

func readAppliedMigrations(
	ctx context.Context,
	queryer schemaQueryer,
) ([]appliedMigration, bool, error) {
	var exists bool
	if err := queryer.QueryRow(
		ctx,
		`SELECT to_regclass($1) IS NOT NULL`,
		schemaMigrationTable,
	).Scan(&exists); err != nil {
		return nil, false, fmt.Errorf("store: inspect schema migration metadata: %w", err)
	}
	if !exists {
		return nil, false, nil
	}

	rows, err := queryer.Query(
		ctx,
		`SELECT version, name, checksum, transactional
		 FROM schema_migration_versions
		 ORDER BY version`,
	)
	if err != nil {
		return nil, true, fmt.Errorf("store: read schema migration metadata: %w", err)
	}
	defer rows.Close()

	var applied []appliedMigration
	for rows.Next() {
		var item appliedMigration
		if err := rows.Scan(
			&item.Version,
			&item.Name,
			&item.Checksum,
			&item.Transactional,
		); err != nil {
			return nil, true, fmt.Errorf("store: scan schema migration metadata: %w", err)
		}
		applied = append(applied, item)
	}
	if err := rows.Err(); err != nil {
		return nil, true, fmt.Errorf("store: iterate schema migration metadata: %w", err)
	}
	return applied, true, nil
}

func validateAppliedMigrations(applied []appliedMigration, catalog []migration) error {
	catalogByVersion := make(map[int64]migration, len(catalog))
	for _, item := range catalog {
		catalogByVersion[item.Version] = item
	}

	for i, item := range applied {
		expectedVersion := int64(i + 1)
		if item.Version != expectedVersion {
			return fmt.Errorf(
				"store: schema migration history has a gap: found version %d where version %d was required",
				item.Version,
				expectedVersion,
			)
		}
		expected, ok := catalogByVersion[item.Version]
		if !ok {
			return fmt.Errorf(
				"store: database schema version %d is newer than embedded migration catalog version %d",
				item.Version,
				MaximumSupportedSchemaVersion,
			)
		}
		switch {
		case item.Name != expected.Name:
			return fmt.Errorf(
				"store: schema migration %d name mismatch: database=%q binary=%q",
				item.Version,
				item.Name,
				expected.Name,
			)
		case item.Checksum != expected.Checksum:
			return fmt.Errorf(
				"store: schema migration %d checksum mismatch: database=%s binary=%s",
				item.Version,
				item.Checksum,
				expected.Checksum,
			)
		case item.Transactional != expected.Transactional:
			return fmt.Errorf(
				"store: schema migration %d transaction mode mismatch: database=%t binary=%t",
				item.Version,
				item.Transactional,
				expected.Transactional,
			)
		}
	}
	return nil
}

func currentSchemaVersion(applied []appliedMigration) int64 {
	if len(applied) == 0 {
		return 0
	}
	return applied[len(applied)-1].Version
}
