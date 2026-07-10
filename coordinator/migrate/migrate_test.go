package migrate

import (
	"context"
	"os"
	"path/filepath"
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
