package trust_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type cohortContextStore struct {
	*memory.MemoryStore
	freezeContext context.Context
}

func (s *cohortContextStore) FreezeLegacyMDMCohort(ctx context.Context) ([]store.LegacyMDMMachine, error) {
	s.freezeContext = ctx
	return s.MemoryStore.FreezeLegacyMDMCohort(ctx)
}

func TestLegacyMDMInitializationBoundsFreezeContext(t *testing.T) {
	for _, name := range []string{"background", "earlier deadline", "cancelled"} {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			var earlier time.Time
			switch name {
			case "earlier deadline":
				earlier = time.Now().Add(5 * time.Second)
				var cancel context.CancelFunc
				ctx, cancel = context.WithDeadline(ctx, earlier)
				defer cancel()
			case "cancelled":
				var cancel context.CancelFunc
				ctx, cancel = context.WithCancel(ctx)
				cancel()
			}
			st := &cohortContextStore{MemoryStore: memory.NewMemory(store.Config{})}
			srv := api.NewServer(registry.New(quietLogger()), st, api.ServerConfig{AppAttestShadow: api.AppAttestShadowConfig{
				ServingEnabled: true, Environment: "production", RolloutPercent: 100,
			}}, quietLogger())
			t.Cleanup(srv.Close)
			before := time.Now()
			err := srv.Trust().InitializeLegacyMDMPolicy(ctx)
			after := time.Now()
			if name == "cancelled" {
				if !errors.Is(err, context.Canceled) {
					t.Fatalf("initialization error=%v, want cancellation", err)
				}
				if st.freezeContext != nil {
					t.Fatal("cancelled initialization reached the durable freeze")
				}
				return
			} else if err != nil {
				t.Fatal(err)
			}
			deadline, ok := st.freezeContext.Deadline()
			if !ok {
				t.Fatal("cohort freeze received an unbounded context")
			}
			if !earlier.IsZero() {
				if !deadline.Equal(earlier) {
					t.Fatalf("freeze deadline=%v, want earlier caller deadline %v", deadline, earlier)
				}
			} else if deadline.Before(before.Add(30*time.Second)) || deadline.After(after.Add(30*time.Second)) {
				t.Fatalf("freeze deadline=%v, want 30-second startup bound", deadline)
			}
			if !errors.Is(st.freezeContext.Err(), context.Canceled) {
				t.Fatal("initialization did not release its freeze context")
			}
		})
	}
}
