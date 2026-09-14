package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type operationsReadStore struct {
	store.Store
	calls           int
	filter          store.RequestProfileFilter
	outcomeLimit    int
	outcomeDeadline time.Duration
}

func (s *operationsReadStore) InferenceRouteRecordsSince(time.Time) []store.InferenceRouteRecord {
	s.calls++
	return []store.InferenceRouteRecord{{RequestID: "live-route", ProviderID: "live-provider", Model: "live-model"}}
}
func (s *operationsReadStore) RejectionRecordsSince(time.Time) []store.RejectionRecord {
	s.calls++
	return []store.RejectionRecord{{RequestID: "live-rejection", ReasonCode: "live-reason", ResolvedModel: "live-model"}}
}
func (s *operationsReadStore) RequestProfilesSinceFiltered(_ time.Time, filter store.RequestProfileFilter) []store.RequestProfileRecord {
	s.calls++
	s.filter = filter
	return []store.RequestProfileRecord{{RequestID: "live-profile"}}
}
func (s *operationsReadStore) FleetSnapshotsSince(time.Time) []store.FleetSnapshotRow {
	s.calls++
	return []store.FleetSnapshotRow{{ProviderID: "live-provider", Model: "live-model"}}
}
func (s *operationsReadStore) RequestOutcomes(ctx context.Context, _ time.Time, _ time.Time, limit int) ([]store.RequestOutcomeRecord, error) {
	s.calls++
	s.outcomeLimit = limit
	if deadline, ok := ctx.Deadline(); ok {
		s.outcomeDeadline = time.Until(deadline)
	}
	return []store.RequestOutcomeRecord{{CoordRequestID: "live-outcome"}}, nil
}

// Exercise registered routes after construction, so a captured dependency or
// missing authorization gate cannot be hidden by a directly constructed owner.
func TestOperationsRoutesUseCurrentBindings(t *testing.T) {
	srv := newProfilerTestServer(t)
	readStore := &operationsReadStore{Store: store.NewMemory(store.Config{})}
	srv.store = readStore
	srv.SetAdminKey("live-admin")
	srv.metrics = NewMetrics()
	srv.metrics.AddCounter("live_operations_counter", 17)
	counters := srv.requestOutcomes
	counters.MarkReceived()
	counters.MarkReceived()
	srv.requestOutcomes = nil
	defer func() { srv.requestOutcomes = counters }()
	liveRegistry := registry.New(srv.logger)
	p := liveRegistry.Register("live-provider", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{{ID: "live-model"}}})
	p.Mu().Lock()
	p.Status = registry.StatusOnline
	p.TrustLevel = registry.TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.Backend = registry.BackendMLXSwift
	p.PublicKey = "test-public-key"
	p.EncryptedResponseChunks = true
	p.PrivacyCapabilities = &protocol.PrivacyCapabilities{TextBackendInprocess: true, TextProxyDisabled: true, AntiDebugEnabled: true, CoreDumpsDisabled: true, EnvScrubbed: true}
	p.Mu().Unlock()
	srv.registry = liveRegistry
	handler := srv.Handler()
	get := func(path, key string) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(http.MethodGet, path, nil)
		if key != "" {
			req.Header.Set("Authorization", "Bearer "+key)
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		return w
	}
	routes := []struct{ path, contentType, marker string }{
		{"/v1/admin/routes", "application/json", "live-route"},
		{"/v1/admin/routes/export", "text/csv", "live-route"},
		{"/v1/admin/routes/export?format=ndjson", "application/x-ndjson", "live-route"},
		{"/v1/admin/rejections", "application/json", "live-rejection"},
		{"/v1/admin/rejections/export", "text/csv", "live-rejection"},
		{"/v1/admin/rejections/export?format=ndjson", "application/x-ndjson", "live-rejection"},
		{"/v1/admin/profiles?provider=p&model=m&final_status=success&coord_request_id=c", "application/json", "live-profile"},
		{"/v1/admin/profiles/export?provider=p&model=m&final_status=success&coord_request_id=c", "application/x-ndjson", "live-profile"},
		{"/v1/admin/snapshots", "application/json", "live-provider"},
		{"/v1/admin/snapshots/export", "application/x-ndjson", "live-provider"},
		{"/v1/admin/request-outcomes?limit=50000", "application/json", "live-outcome"},
		{"/v1/admin/metrics", "application/json", "live_operations_counter"},
		{"/v1/admin/metrics?format=prom", "text/plain; version=0.0.4", "live_operations_counter 17"},
		{"/v1/admin/utilization", "application/json", "live-model"},
	}
	for _, route := range routes {
		t.Run(route.path, func(t *testing.T) {
			before := readStore.calls
			for _, key := range []string{"", "admin-test-key"} {
				w := get(route.path, key)
				if w.Code != http.StatusForbidden || readStore.calls != before {
					t.Fatalf("denied route read dependency: status=%d reads=%d->%d", w.Code, before, readStore.calls)
				}
			}
			w := get(route.path, "live-admin")
			if w.Code != 200 || w.Header().Get("Content-Type") != route.contentType || !strings.Contains(w.Body.String(), route.marker) {
				t.Fatalf("current route: status=%d type=%s body=%s", w.Code, w.Header().Get("Content-Type"), w.Body.String())
			}
			if strings.Contains(route.path, "/export") && !strings.Contains(w.Header().Get("Content-Disposition"), "attachment;") {
				t.Fatal("export lost download header")
			}
		})
	}
	if readStore.filter != (store.RequestProfileFilter{ProviderID: "p", Model: "m", FinalStatus: "success", CoordRequestID: "c"}) {
		t.Fatalf("profile filters not passed to store: %+v", readStore.filter)
	}
	if readStore.outcomeLimit != 1000 || readStore.outcomeDeadline <= 0 || readStore.outcomeDeadline > 5*time.Second {
		t.Fatalf("outcome bounds: limit=%d deadline=%s", readStore.outcomeLimit, readStore.outcomeDeadline)
	}
	for _, available := range []bool{false, true} {
		if available {
			srv.requestOutcomes = counters
		}
		w := get("/v1/admin/request-outcomes", "live-admin")
		var body struct {
			Counters struct {
				Available bool  `json:"available"`
				Received  int64 `json:"received"`
			} `json:"process_counters"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		if body.Counters.Available != available || (available && body.Counters.Received != 2) {
			t.Fatalf("current counter reader: %+v", body)
		}
	}
}
