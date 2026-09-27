package baserewards

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type sharedEpochEngineStore struct {
	*engineStore
	read    chan struct{}
	release chan struct{}
}

func (s *sharedEpochEngineStore) WithEpochSettlementLock(ctx context.Context, epoch string, fn func() error) error {
	return s.inner.WithEpochSettlementLock(ctx, epoch, fn)
}

func (s *sharedEpochEngineStore) ListFloorDrawsForEpoch(ctx context.Context, epoch string) ([]store.ProviderFloorDraw, error) {
	draws, err := s.inner.ListFloorDrawsForEpoch(ctx, epoch)
	if s.read != nil {
		close(s.read)
		s.read = nil
		select {
		case <-s.release:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return draws, err
}

func TestConcurrentDisjointRewardCohortsShareOneEpochBudget(t *testing.T) {
	epoch, start, end, clock := closedEpoch()
	shared := store.NewMemory(store.Config{})
	firstRead, release := make(chan struct{}), make(chan struct{})
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	engines := make([]*Engine, 0, 2)
	for _, id := range []string{"a", "b"} {
		st := &sharedEpochEngineStore{engineStore: newEngineStore()}
		st.inner = shared
		if id == "a" {
			st.read = firstRead
			st.release = release
		}
		reg := registry.New(testLogger())
		p := addProvider(reg, id, id, id, "Mac15,8", 64)
		setSerial(p, id, "Mac15,8")
		p.AccountID = id
		st.sessions = []store.ProviderSession{fullUptimeSession(id, id, id, id, start, end)}
		e := newTestEngine(st, reg, clock)
		e.cfg.PoolBudgetMicroUSD = 1000 * 8928
		engines = append(engines, e)
	}
	done := make(chan error, 2)
	go func() { _, err := engines[0].SettleEpoch(ctx, epoch); done <- err }()
	select {
	case <-firstRead:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	secondDone := make(chan struct{})
	go func() { _, err := engines[1].SettleEpoch(ctx, epoch); done <- err; close(secondDone) }()
	// An old no-op memory epoch lock lets the second cohort commit against the
	// same captured empty pool while the first allocation is paused.
	select {
	case <-secondDone:
	case <-time.After(50 * time.Millisecond):
	}
	close(release)
	for range 2 {
		if err := <-done; err != nil {
			t.Fatal(err)
		}
	}
	if spent, err := shared.SumFloorDrawsForEpoch(ctx, epoch); err != nil || spent != 1000 {
		t.Fatalf("disjoint cohorts overspent: %d %v", spent, err)
	}
}
