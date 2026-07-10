package store

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"path"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

const (
	// MinimumSupportedSchemaVersion and MaximumSupportedSchemaVersion bound the
	// database schemas this coordinator binary may serve against.
	MinimumSupportedSchemaVersion int64 = 2
	MaximumSupportedSchemaVersion int64 = 3

	schemaMigrationTable = "schema_migration_versions"
)

var (
	migrationFilenamePattern = regexp.MustCompile(`^([0-9]{6})_([a-z0-9_]+)\.sql$`)
	sqlIdentifierPattern     = regexp.MustCompile(`^[a-z_][a-z0-9_]*$`)
	broadExceptionPattern    = regexp.MustCompile(`(?i)\bEXCEPTION\s+WHEN\s+OTHERS\b`)

	// Versioned migrations are embedded so the standalone migrate command and
	// the serving binary validate against exactly the same catalog.
	//
	//go:embed migrations/[0-9]*.sql
	migrationFiles embed.FS
)

type migration struct {
	Version         int64
	Name            string
	Checksum        string
	SQL             string
	Transactional   bool
	Bootstrap       bool
	ConcurrentIndex string
}

func loadMigrations() ([]migration, error) {
	entries, err := fs.ReadDir(migrationFiles, "migrations")
	if err != nil {
		return nil, fmt.Errorf("store: read embedded migrations: %w", err)
	}

	migrations := make([]migration, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		match := migrationFilenamePattern.FindStringSubmatch(entry.Name())
		if match == nil {
			return nil, fmt.Errorf("store: invalid migration filename %q", entry.Name())
		}
		version, err := strconv.ParseInt(match[1], 10, 64)
		if err != nil {
			return nil, fmt.Errorf("store: parse migration version in %q: %w", entry.Name(), err)
		}
		body, err := migrationFiles.ReadFile(path.Join("migrations", entry.Name()))
		if err != nil {
			return nil, fmt.Errorf("store: read migration %q: %w", entry.Name(), err)
		}
		sum := sha256.Sum256(body)
		m := migration{
			Version:       version,
			Name:          match[2],
			Checksum:      hex.EncodeToString(sum[:]),
			SQL:           string(body),
			Transactional: true,
		}
		if err := parseMigrationDirectives(&m); err != nil {
			return nil, fmt.Errorf("store: migration %q: %w", entry.Name(), err)
		}
		if err := validateMigrationSQL(m); err != nil {
			return nil, fmt.Errorf("store: migration %q: %w", entry.Name(), err)
		}
		migrations = append(migrations, m)
	}

	sort.Slice(migrations, func(i, j int) bool {
		return migrations[i].Version < migrations[j].Version
	})
	for i, m := range migrations {
		expected := int64(i + 1)
		if m.Version != expected {
			return nil, fmt.Errorf("store: migration versions must be contiguous from 1: got %d, want %d", m.Version, expected)
		}
	}
	if len(migrations) == 0 {
		return nil, errors.New("store: no embedded schema migrations")
	}
	if !migrations[0].Bootstrap {
		return nil, errors.New("store: migration version 1 must bootstrap schema metadata")
	}
	if latest := migrations[len(migrations)-1].Version; latest != MaximumSupportedSchemaVersion {
		return nil, fmt.Errorf(
			"store: migration catalog ends at version %d, supported maximum is %d",
			latest,
			MaximumSupportedSchemaVersion,
		)
	}
	if MinimumSupportedSchemaVersion < 1 || MinimumSupportedSchemaVersion > MaximumSupportedSchemaVersion {
		return nil, errors.New("store: invalid supported schema version range")
	}
	return migrations, nil
}

func parseMigrationDirectives(m *migration) error {
	for _, line := range strings.Split(m.SQL, "\n") {
		line = strings.TrimSpace(line)
		switch {
		case line == "-- darkbloom:transaction=false":
			m.Transactional = false
		case line == "-- darkbloom:transaction=true":
			m.Transactional = true
		case line == "-- darkbloom:bootstrap=true":
			m.Bootstrap = true
		case strings.HasPrefix(line, "-- darkbloom:concurrent-index="):
			m.ConcurrentIndex = strings.TrimPrefix(line, "-- darkbloom:concurrent-index=")
			if !sqlIdentifierPattern.MatchString(m.ConcurrentIndex) {
				return fmt.Errorf("invalid concurrent index name %q", m.ConcurrentIndex)
			}
		}
	}
	if m.ConcurrentIndex != "" && m.Transactional {
		return errors.New("concurrent index migration must set darkbloom:transaction=false")
	}
	if m.Bootstrap && (m.Version != 1 || m.Transactional) {
		return errors.New("bootstrap migration must be nontransactional version 1")
	}
	return nil
}

func validateMigrationSQL(m migration) error {
	if broadExceptionPattern.MatchString(m.SQL) {
		return errors.New("broadly swallows PostgreSQL errors with WHEN OTHERS")
	}
	return nil
}
