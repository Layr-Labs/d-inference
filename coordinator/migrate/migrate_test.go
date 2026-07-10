package migrate

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestApplyDir_IdempotentOrder(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "0002_b.sql"), []byte("SELECT 2"), 0o644)
	_ = os.WriteFile(filepath.Join(dir, "0001_a.sql"), []byte("SELECT 1"), 0o644)

	var applied []string
	seen := map[string]bool{}
	r := &Runner{
		Exec: func(ctx context.Context, sql string) error {
			applied = append(applied, sql)
			return nil
		},
		Record: func(ctx context.Context, name string) error {
			seen[name] = true
			return nil
		},
		Applied: func(ctx context.Context, name string) (bool, error) {
			return seen[name], nil
		},
	}
	if err := r.ApplyDir(context.Background(), dir); err != nil {
		t.Fatal(err)
	}
	if len(applied) != 2 || applied[0] != "SELECT 1" || applied[1] != "SELECT 2" {
		t.Fatalf("order=%v", applied)
	}
	// Second pass is no-op.
	if err := r.ApplyDir(context.Background(), dir); err != nil {
		t.Fatal(err)
	}
	if len(applied) != 2 {
		t.Fatalf("idempotent failed: %v", applied)
	}
}

func TestApplyDir_RealRustCoordMigrationsLexOrder(t *testing.T) {
	// Resolve repo-relative migrations from this package.
	dir := filepath.Join("..", "..", "coordinator-rs", "migrations")
	if _, err := os.Stat(dir); err != nil {
		t.Skipf("migrations dir not present: %v", err)
	}
	var applied []string
	seen := map[string]bool{}
	r := &Runner{
		Exec: func(ctx context.Context, sql string) error {
			if !strings.Contains(sql, "rust_coord") && !strings.Contains(sql, "late_terminals") {
				return fmt.Errorf("unexpected migration body")
			}
			applied = append(applied, sql[:min(40, len(sql))])
			return nil
		},
		Record: func(ctx context.Context, name string) error {
			seen[name] = true
			return nil
		},
		Applied: func(ctx context.Context, name string) (bool, error) {
			return seen[name], nil
		},
	}
	if err := r.ApplyDir(context.Background(), dir); err != nil {
		t.Fatal(err)
	}
	if len(applied) < 2 {
		t.Fatalf("expected at least 0001+0002, got %d", len(applied))
	}
	// Second pass no-op.
	if err := r.ApplyDir(context.Background(), dir); err != nil {
		t.Fatal(err)
	}
	if len(applied) < 2 || len(seen) != len(applied) {
		t.Fatalf("idempotent/record mismatch applied=%d seen=%d", len(applied), len(seen))
	}
}
