// Package migrate applies external schema changes. Application startup must
// never run DDL (plan §20). The rollback-safe Go baseline and Rust share this
// discipline: operators run migrations before starting either binary.
package migrate

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Runner applies ordered .sql files from a directory.
type Runner struct {
	// Exec runs a single SQL statement/batch against the database.
	Exec func(ctx context.Context, sql string) error
	// Record marks a migration filename as applied (idempotent).
	Record func(ctx context.Context, name string) error
	// Applied reports whether a migration filename was already applied.
	Applied func(ctx context.Context, name string) (bool, error)
}

// ApplyDir applies all *.sql files in dir in lexicographic order.
func (r *Runner) ApplyDir(ctx context.Context, dir string) error {
	if r.Exec == nil || r.Record == nil || r.Applied == nil {
		return fmt.Errorf("migrate: runner not fully configured")
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return fmt.Errorf("migrate: read dir: %w", err)
	}
	var files []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if strings.HasSuffix(name, ".sql") {
			files = append(files, name)
		}
	}
	sort.Strings(files)
	for _, name := range files {
		done, err := r.Applied(ctx, name)
		if err != nil {
			return err
		}
		if done {
			continue
		}
		body, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return fmt.Errorf("migrate: read %s: %w", name, err)
		}
		ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
		err = r.Exec(ctx, string(body))
		cancel()
		if err != nil {
			return fmt.Errorf("migrate: apply %s: %w", name, err)
		}
		if err := r.Record(ctx, name); err != nil {
			return fmt.Errorf("migrate: record %s: %w", name, err)
		}
	}
	return nil
}
