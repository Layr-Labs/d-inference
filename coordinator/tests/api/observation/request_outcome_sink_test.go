package observation_test

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	production "github.com/eigeninference/d-inference/coordinator/api/observation"

	outcomes "github.com/eigeninference/d-inference/coordinator/internal/observation/outcomes"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type failedRequestOutcomeStore struct {
	store.Store
	panicWrite bool
}

func (s *failedRequestOutcomeStore) RecordRequestOutcomes(context.Context, []store.RequestOutcomeRecord) error {
	if s.panicWrite {
		panic("fake failing dependency")
	}
	return errors.New("fake failing dependency")
}

func (s *failedRequestOutcomeStore) RequestOutcomes(context.Context, time.Time, time.Time, int) ([]store.RequestOutcomeRecord, error) {
	return nil, errors.New("fake failing dependency")
}

func TestRequestOutcomeSinkPeriodicFlush(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		st := memory.NewMemory(store.Config{})
		sink := outcomes.New(outcomes.Dependencies{Store: st}, 2)
		defer sink.Close()
		now := time.Now()
		sink.Submit(store.RequestOutcomeRecord{CoordRequestID: "periodic-flush", SchemaVersion: store.RequestOutcomeSchemaVersion, Revision: 1, ReceivedAt: now, UpdatedAt: now, FinalizedAt: &now})
		// One record cannot fill a batch. It must persist while the sink is open,
		// independently of the close-and-drain path used by synchronous fixtures.
		synctest.Wait()
		time.Sleep(99 * time.Millisecond)
		synctest.Wait()
		rows, err := st.RequestOutcomes(context.Background(), time.Time{}, time.Now(), 10)
		if err != nil || len(rows) != 0 {
			t.Fatalf("flushed before the first tick: rows=%+v err=%v", rows, err)
		}
		time.Sleep(time.Millisecond)
		synctest.Wait()
		rows, err = st.RequestOutcomes(context.Background(), time.Time{}, time.Now(), 10)
		if err != nil || len(rows) != 1 {
			t.Fatalf("periodic flush missing: rows=%+v err=%v", rows, err)
		}
		row := rows[0]
		if row.CoordRequestID != "periodic-flush" || row.Revision != 1 {
			t.Fatalf("periodic flush changed the record: %+v", row)
		}
	})
}

func TestRequestOutcomeSinkLossIsExplicit(t *testing.T) {
	q := outcomes.NewQueue(1, nil)
	q.Submit(store.RequestOutcomeRecord{})
	q.Submit(store.RequestOutcomeRecord{})
	if q.Stats().Dropped != 1 {
		t.Fatal("full queue did not count drop")
	}
	q.Close()
	q.Submit(store.RequestOutcomeRecord{})
	if q.Stats().Dropped != 2 {
		t.Fatal("closed queue did not count drop")
	}
	for _, panicWrite := range []bool{false, true} {
		st := &failedRequestOutcomeStore{Store: memory.NewMemory(store.Config{}), panicWrite: panicWrite}
		sink := outcomes.New(outcomes.Dependencies{Store: st}, 2)
		sink.Submit(store.RequestOutcomeRecord{CoordRequestID: "a"})
		sink.Close()
		if sink.Stats().Failed != 1 || sink.Stats().Written != 0 {
			t.Fatalf("failed sink fabricated persistence: failed=%d written=%d", sink.Stats().Failed, sink.Stats().Written)
		}
	}
}

func TestRequestOutcomeAdminReadFailureIsNotKnownZero(t *testing.T) {
	st := &failedRequestOutcomeStore{Store: memory.NewMemory(store.Config{})}
	a := access.New(st, quietLogger(), 1<<20, access.Hooks{})
	a.SetAdminKey("outcome-admin")
	s := production.New(production.Dependencies{Store: st, Logger: quietLogger(), Hooks: production.Hooks{RequireAdminKey: a.RequireAdminKey}})
	t.Cleanup(s.Close)
	r := httptest.NewRequest(http.MethodGet, "/v1/admin/request-outcomes", nil)
	r.Header.Set("Authorization", "Bearer outcome-admin")
	w := httptest.NewRecorder()
	s.HandleAdminRequestOutcomes(w, r)
	if w.Code != 503 {
		t.Fatalf("read error became %d: %s", w.Code, w.Body.String())
	}
	w = httptest.NewRecorder()
	s.HandleAdminRequestOutcomes(w, httptest.NewRequest(http.MethodGet, "/v1/admin/request-outcomes", nil))
	if w.Code < 400 {
		t.Fatal("admin source accessible without authorization")
	}
}
