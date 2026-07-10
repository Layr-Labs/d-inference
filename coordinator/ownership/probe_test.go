package ownership

import (
	"context"
	"errors"
	"testing"
)

func TestApplyProbe_MissingSchemaIsInactive(t *testing.T) {
	g := NewGate(true)
	err := g.ApplyProbe(context.Background(), func(ctx context.Context) (bool, string, error) {
		return false, "", errors.New(`relation "rust_coord.inference_jobs" does not exist (SQLSTATE 42P01)`)
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := g.CheckStartup(context.Background()); err != nil {
		t.Fatalf("missing schema should allow startup: %v", err)
	}
}

func TestApplyProbe_ActiveBlocksStartup(t *testing.T) {
	g := NewGate(true)
	if err := g.ApplyProbe(context.Background(), func(ctx context.Context) (bool, string, error) {
		return true, "jobs", nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := g.CheckStartup(context.Background()); err != ErrUnsafeStartup {
		t.Fatalf("err=%v", err)
	}
}
