package legacymdm_test

import (
	"context"
	"errors"
	"testing"
	"time"

	attestservice "github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/legacymdm"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type interruptedBackfillStore struct {
	*memory.MemoryStore
	backfill func(context.Context, int) (int, error)
}

func (s *interruptedBackfillStore) BackfillMachineInventory(ctx context.Context, limit int) (int, error) {
	return s.backfill(ctx, limit)
}

func TestBackfillFailureDoesNotFreezeCohort(t *testing.T) {
	for _, mode := range []string{"error", "cancelled", "deadline", "cancelled at zero"} {
		t.Run(mode, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			failure := errors.New("inventory unavailable")
			if mode == "cancelled" || mode == "cancelled at zero" {
				failure = context.Canceled
			}
			if mode == "deadline" {
				var stop context.CancelFunc
				ctx, stop = context.WithDeadline(ctx, time.Now().Add(-time.Second))
				defer stop()
				failure = context.DeadlineExceeded
			}
			st := &interruptedBackfillStore{MemoryStore: memory.NewMemory(store.Config{})}
			calls := 0
			st.backfill = func(_ context.Context, limit int) (int, error) {
				calls++
				if limit != 100 {
					t.Fatalf("batch limit=%d", limit)
				}
				if mode == "cancelled at zero" {
					cancel()
					return 0, nil
				}
				if calls == 1 {
					if mode == "cancelled" {
						cancel()
					}
					return 100, nil
				}
				return 0, failure
			}
			cfg := attestservice.Config{ServingEnabled: true, Environment: "production", RolloutPercent: 100}
			policy := legacymdm.New(store.NewCached(st, store.CacheConfig{}))
			if err := policy.Initialize(ctx, cfg); !errors.Is(err, failure) {
				t.Fatalf("error=%v, want %v", err, failure)
			}
			if policy.IdentityAllowed("old", "key", "serial") {
				t.Fatal("failed backfill left eligibility open")
			}
			seedMachine(t, st.MemoryStore, "old", "key", "serial")
			st.backfill = func(context.Context, int) (int, error) { return 0, nil }
			if err := policy.Initialize(context.Background(), cfg); err != nil {
				t.Fatal(err)
			}
			if !policy.IdentityAllowed("old", "key", "serial") {
				t.Fatal("failed backfill prematurely persisted the freeze marker")
			}
		})
	}
}
