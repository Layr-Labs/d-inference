package registry

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type orderedReputationStore struct {
	store.Store
	records []store.ProviderRecord
}

func (s *orderedReputationStore) ListProviderRecords(context.Context) ([]store.ProviderRecord, error) {
	return s.records, nil
}

func TestStoredProviderLookupKeepsNewestInEitherOrder(t *testing.T) {
	now := time.Now()
	newest := store.ProviderRecord{ID: "new", SerialNumber: "serial", SEPublicKey: "key", LastSeen: now}
	oldest := store.ProviderRecord{ID: "old", SerialNumber: "serial", SEPublicKey: "key", LastSeen: now.Add(-time.Hour)}
	for _, records := range [][]store.ProviderRecord{{newest, oldest}, {oldest, newest}} {
		r := New(testLogger())
		r.SetStore(&orderedReputationStore{Store: store.NewMemory(store.Config{}), records: records})
		got := r.LoadStoredProviders()
		for _, key := range []string{"serial", "sekey:key"} {
			if got[key].ID != "new" {
				t.Errorf("%s selected %s", key, got[key].ID)
			}
		}
	}
}

type blockedReputationStore struct {
	store.Store
	writes    atomic.Int64
	started   chan struct{}
	release   chan struct{}
	completed chan struct{}
}

func (s *blockedReputationStore) UpsertReputation(ctx context.Context, id string, rep store.ReputationRecord) error {
	n := s.writes.Add(1)
	if n == 1 {
		close(s.started)
		select {
		case <-s.release:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	err := s.Store.UpsertReputation(ctx, id, rep)
	if n == 2 {
		close(s.completed)
	}
	return err
}
func waitReputationSignal(t *testing.T, ch <-chan struct{}) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(3 * time.Second):
		t.Fatal("persistence timed out")
	}
}

func TestReputationPersistenceCoalescesWithoutRegressing(t *testing.T) {
	st := &blockedReputationStore{Store: store.NewMemory(store.Config{}), started: make(chan struct{}), release: make(chan struct{}), completed: make(chan struct{})}
	r := New(testLogger())
	r.SetStore(st)
	p := &Provider{ID: "node", Reputation: NewReputation()}
	p.Reputation.RecordJobSuccess()
	r.persistReputation(p)
	waitReputationSignal(t, st.started)
	for i := 0; i < 100; i++ {
		p.mu.Lock()
		p.Reputation.RecordJobSuccess()
		p.mu.Unlock()
		r.persistReputation(p)
	}
	if got := st.writes.Load(); got != 1 {
		t.Fatalf("%d concurrent writes while first is blocked", got)
	}
	close(st.release)
	waitReputationSignal(t, st.completed)
	got, err := st.GetReputation(context.Background(), p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.TotalJobs != 101 || got.SuccessfulJobs != 101 {
		t.Fatalf("persisted %+v, want 101 successes", got)
	}
}
