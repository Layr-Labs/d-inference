package reporting_test

import (
	"context"
	"errors"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// A failed aggregate must never become a cached successful empty list.
type unavailableDemandStore struct {
	store.Store
	fail bool
}

func (s *unavailableDemandStore) ModelDemand(ctx context.Context, a, b time.Time) (store.ModelDemandSnapshot, error) {
	if s.fail {
		return store.ModelDemandSnapshot{}, errors.New("unavailable")
	}
	return s.Store.(store.ModelDemandStore).ModelDemand(ctx, a, b)
}

func (s *unavailableDemandStore) PruneModelDemand(ctx context.Context, a time.Time, b int) (int, error) {
	return 0, nil
}

func TestModelDemandFailureIsNotCached(t *testing.T) {
	failing := &unavailableDemandStore{Store: memory.NewMemory(store.Config{}), fail: true}
	s := newStatsSnapshotServer(failing)
	request := func() int {
		w := httptest.NewRecorder()
		s.HandleModelDemand(w, httptest.NewRequest("GET", "/?window=24h", nil))
		return w.Code
	}
	if got := request(); got != 503 {
		t.Fatalf("failure status %d", got)
	}
	failing.fail = false
	if got := request(); got != 200 {
		t.Fatalf("recovered status %d", got)
	}
}
