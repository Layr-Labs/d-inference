package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
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

func TestRequestOutcomeSinkLossIsExplicit(t *testing.T) {
	q := &requestOutcomeSink{s: &Server{}, ch: make(chan store.RequestOutcomeRecord, 1)}
	q.submit(store.RequestOutcomeRecord{})
	q.submit(store.RequestOutcomeRecord{})
	if q.dropped.Load() != 1 {
		t.Fatal("full queue did not count drop")
	}
	q.closed = true
	q.submit(store.RequestOutcomeRecord{})
	if q.dropped.Load() != 2 {
		t.Fatal("closed queue did not count drop")
	}
	for _, panicWrite := range []bool{false, true} {
		s := &Server{store: &failedRequestOutcomeStore{Store: store.NewMemory(store.Config{}), panicWrite: panicWrite}}
		sink := newRequestOutcomeSink(s, 2)
		sink.submit(store.RequestOutcomeRecord{CoordRequestID: "a"})
		sink.close()
		if sink.failed.Load() != 1 || sink.written.Load() != 0 {
			t.Fatalf("failed sink fabricated persistence: failed=%d written=%d", sink.failed.Load(), sink.written.Load())
		}
	}
}
func TestRequestOutcomeAdminReadFailureIsNotKnownZero(t *testing.T) {
	s := &Server{store: &failedRequestOutcomeStore{Store: store.NewMemory(store.Config{})}, adminKey: "outcome-admin"}
	r := httptest.NewRequest(http.MethodGet, "/v1/admin/request-outcomes", nil)
	r.Header.Set("Authorization", "Bearer outcome-admin")
	w := httptest.NewRecorder()
	s.handleAdminRequestOutcomes(w, r)
	if w.Code != 503 {
		t.Fatalf("read error became %d: %s", w.Code, w.Body.String())
	}
	w = httptest.NewRecorder()
	s.handleAdminRequestOutcomes(w, httptest.NewRequest(http.MethodGet, "/v1/admin/request-outcomes", nil))
	if w.Code < 400 {
		t.Fatal("admin source accessible without authorization")
	}
}

func TestRequestOutcomeAdminBoundedSourceRoute(t *testing.T) {
	_, st, srv, ts := setupTTFTFailoverServer(t)
	defer srv.Close()
	srv.SetAdminKey("outcome-admin")
	now := time.Now().Add(-time.Second)
	for _, id := range []string{"admin-a", "admin-b"} {
		if err := st.RecordRequestOutcomes(context.Background(), []store.RequestOutcomeRecord{{CoordRequestID: id, SchemaVersion: 1, Revision: 1, ReceivedAt: now, UpdatedAt: now, Endpoint: "/v1/messages", Termination: "in_progress", Attempts: []store.RequestAttemptOutcome{}}}); err != nil {
			t.Fatal(err)
		}
	}
	for _, auth := range []bool{false, true} {
		req, _ := http.NewRequest("GET", ts.URL+"/v1/admin/request-outcomes?limit=1", nil)
		if auth {
			req.Header.Set("Authorization", "Bearer outcome-admin")
		}
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		if !auth {
			res.Body.Close()
			if res.StatusCode < 400 {
				t.Fatal("unprotected registered admin route")
			}
			continue
		}
		var body struct {
			SchemaVersion int                          `json:"schema_version"`
			Count         int                          `json:"count"`
			Truncated     bool                         `json:"possibly_truncated"`
			Coverage      string                       `json:"coverage"`
			Data          []store.RequestOutcomeRecord `json:"data"`
		}
		err = json.NewDecoder(res.Body).Decode(&body)
		res.Body.Close()
		if err != nil || res.StatusCode != 200 || body.SchemaVersion != 1 || body.Count != 1 || !body.Truncated || body.Coverage != "observed_received_cohort" || len(body.Data) != 1 {
			t.Fatalf("bounded source status=%d body=%+v err=%v", res.StatusCode, body, err)
		}
	}
}
