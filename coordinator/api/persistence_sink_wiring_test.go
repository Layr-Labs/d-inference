package api

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	profiling "github.com/eigeninference/d-inference/coordinator/telemetry/profiler"
)

// Queue ownership must not capture an obsolete store at construction. The
// existing Server adapters resolve the store when a batch is ready to write.
func TestPersistenceSinksUseCurrentStore(t *testing.T) {
	for _, kind := range []string{"profile", "outcome"} {
		t.Run(kind, func(t *testing.T) {
			initial := store.NewMemory(store.Config{})
			current := store.NewMemory(store.Config{})
			s := &Server{store: initial, logger: quietLogger()}
			var submit func()
			var count func(*store.MemoryStore) int
			switch kind {
			case "profile":
				s.profiler = newProfiler(s, profiling.Config{Enabled: true, SampleRate: 1}, 4)
				t.Cleanup(s.profiler.Close)
				rp := registry.NewRequestProfile(time.Now(), "current-store", nil, 0)
				ap := rp.NewAttempt("attempt", 0, "")
				ap.SetOutcome("error", "provider_error", "", "error", "")
				submit = func() {
					if !s.profiler.Submit(rp, ap) {
						t.Fatal("empty profile queue rejected the record")
					}
				}
				count = func(st *store.MemoryStore) int { return len(st.RequestProfilesSince(time.Time{})) }
			case "outcome":
				s.requestOutcomes = newRequestOutcomeSink(s, 4)
				t.Cleanup(s.requestOutcomes.Close)
				submit = func() {
					now := time.Now()
					s.requestOutcomes.Submit(store.RequestOutcomeRecord{CoordRequestID: "current-store", SchemaVersion: store.RequestOutcomeSchemaVersion, Revision: 1, ReceivedAt: now, UpdatedAt: now})
				}
				count = func(st *store.MemoryStore) int {
					rows, err := st.RequestOutcomes(context.Background(), time.Time{}, time.Now().Add(time.Second), 10)
					if err != nil {
						t.Fatal(err)
					}
					return len(rows)
				}
			}
			// No job exists yet. The following channel send orders this lookup
			// change before the worker's first build or write.
			s.store = current
			submit()
			deadline := time.Now().Add(3 * time.Second)
			for count(current) == 0 && time.Now().Before(deadline) {
				time.Sleep(time.Millisecond)
			}
			if got := count(current); got != 1 {
				t.Fatalf("current store has %d rows, want 1", got)
			}
			if got := count(initial); got != 0 {
				t.Fatalf("obsolete constructor store has %d rows, want 0", got)
			}
		})
	}
}
