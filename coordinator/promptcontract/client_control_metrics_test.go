package promptcontract

import (
	"context"
	"errors"
	"net/http"
	"path/filepath"
	"reflect"
	"sync/atomic"
	"testing"
	"time"
)

const validSidecarMetricsBody = `{"status":"ok","ready":true,"loaded_contracts":2,"loading_contracts":0,
"max_loaded_contracts":4,"planning_permits_available":3,"max_planning_concurrency":4,
"metrics":{"plans":{"started":9,"succeeded":8,"cold_only":0,"failed":1,"at_capacity":0,"not_ready":0,"timed_out":0,
"latency_us":{"count":8,"total_us":80,"max_us":20,"buckets":[{"less_than_or_equal_us":50,"cumulative_count":8}]}},
"contract_loads":{"cold":1,"warm":2,"waited":0,"failed":0,"cold_latency_us":{"count":1,"total_us":5,"max_us":5,"buckets":[]}},
"preloads":{"runs":3,"failed":1,"contracts":2}}}`

func TestClientMetricsDecodesStatusAndCachesMetrics(t *testing.T) {
	var paths atomic.Value
	server, socket := startUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths.Store(r.Method + " " + r.URL.Path)
		_, _ = w.Write([]byte(validSidecarMetricsBody))
	}))
	defer server.Close()
	client := NewClient(ClientConfig{SocketPath: socket})
	defer client.Close()

	status, err := client.Metrics(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if got := paths.Load(); got != "GET /metrics" {
		t.Fatalf("request = %v, want GET /metrics", got)
	}
	if status.Status != "ok" || !status.Ready || status.LoadedContracts != 2 || status.MaxLoadedContracts != 4 ||
		status.PlanningPermitsAvailable != 3 || status.MaxPlanningConcurrency != 4 {
		t.Fatalf("status = %+v", status)
	}
	metrics := client.SidecarMetrics()
	if metrics.Plans.Started != 9 || metrics.Plans.Failed != 1 || metrics.ContractLoads.Warm != 2 ||
		metrics.Preloads.Runs != 3 || metrics.Preloads.Contracts != 2 {
		t.Fatalf("cached metrics = %+v", metrics)
	}
	buckets := metrics.Plans.LatencyUS.Buckets
	if len(buckets) != 1 || buckets[0].LessThanOrEqualUS == nil || *buckets[0].LessThanOrEqualUS != 50 ||
		buckets[0].CumulativeCount != 8 {
		t.Fatalf("plan latency buckets = %+v", buckets)
	}
	// The cache hands out copies, so a caller cannot change the stored buckets.
	buckets[0].CumulativeCount = 99
	if client.SidecarMetrics().Plans.LatencyUS.Buckets[0].CumulativeCount != 8 {
		t.Fatal("SidecarMetrics returned a shared bucket slice")
	}
}

func TestClientMetricsRejectsBadResponses(t *testing.T) {
	tests := []struct {
		name    string
		status  int
		body    string
		wantErr error
	}{
		{name: "http error", status: http.StatusInternalServerError, body: `{}`, wantErr: ErrSidecarUnavailable},
		{name: "unknown field", status: http.StatusOK, body: `{"status":"ok","extra":1}`, wantErr: ErrSidecarUnavailable},
		{name: "trailing json", status: http.StatusOK, body: `{} {}`, wantErr: ErrSidecarUnavailable},
		{name: "unknown status", status: http.StatusOK, body: `{"status":"busy","max_loaded_contracts":1,"max_planning_concurrency":1}`, wantErr: ErrPreloadRejected},
		{name: "ready disagrees with status", status: http.StatusOK, body: `{"status":"degraded","ready":true,"max_loaded_contracts":1,"max_planning_concurrency":1}`, wantErr: ErrPreloadRejected},
		{name: "zero max loaded", status: http.StatusOK, body: `{"status":"starting","max_planning_concurrency":1}`, wantErr: ErrPreloadRejected},
		{name: "loaded above max", status: http.StatusOK, body: `{"status":"ok","ready":true,"loaded_contracts":3,"max_loaded_contracts":2,"max_planning_concurrency":1}`, wantErr: ErrPreloadRejected},
		{name: "permits above max", status: http.StatusOK, body: `{"status":"ok","ready":true,"max_loaded_contracts":2,"planning_permits_available":2,"max_planning_concurrency":1}`, wantErr: ErrPreloadRejected},
		{name: "negative loading", status: http.StatusOK, body: `{"status":"ok","ready":true,"loading_contracts":-1,"max_loaded_contracts":2,"max_planning_concurrency":1}`, wantErr: ErrPreloadRejected},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server, socket := startUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(test.status)
				_, _ = w.Write([]byte(test.body))
			}))
			defer server.Close()
			client := NewClient(ClientConfig{SocketPath: socket})
			defer client.Close()
			status, err := client.Metrics(context.Background())
			if !errors.Is(err, test.wantErr) {
				t.Fatalf("error = %v, want %v", err, test.wantErr)
			}
			if !reflect.DeepEqual(status, SidecarStatus{}) {
				t.Fatalf("status = %+v, want zero value on error", status)
			}
			if client.SidecarMetrics().Plans.Started != 0 {
				t.Fatal("rejected response changed cached metrics")
			}
		})
	}
}

func TestClientMetricsReportsMissingSocket(t *testing.T) {
	client := NewClient(ClientConfig{SocketPath: filepath.Join(t.TempDir(), "absent.sock")})
	defer client.Close()
	if _, err := client.Metrics(context.Background()); !errors.Is(err, ErrSidecarUnavailable) {
		t.Fatalf("error = %v, want ErrSidecarUnavailable", err)
	}
	if stats := client.Stats(); stats.HealthTimeouts != 0 {
		t.Fatalf("dial failure counted as timeout: %+v", stats)
	}
}

func TestClientHealthGetCountsTimeouts(t *testing.T) {
	release := make(chan struct{})
	server, socket := startUnixHTTPServer(t, http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		// Hold the response until the client gives up or the test ends.
		select {
		case <-r.Context().Done():
		case <-release:
		}
	}))
	defer server.Close()
	defer close(release)
	client := NewClient(ClientConfig{SocketPath: socket, HealthTimeout: 20 * time.Millisecond})
	defer client.Close()

	if _, err := client.Metrics(context.Background()); !errors.Is(err, ErrSidecarUnavailable) {
		t.Fatalf("metrics error = %v, want ErrSidecarUnavailable", err)
	}
	if _, err := client.Ready(context.Background()); !errors.Is(err, ErrSidecarUnavailable) {
		t.Fatalf("ready error = %v, want ErrSidecarUnavailable", err)
	}
	if stats := client.Stats(); stats.HealthTimeouts != 2 {
		t.Fatalf("health timeouts = %d, want 2", stats.HealthTimeouts)
	}
}
