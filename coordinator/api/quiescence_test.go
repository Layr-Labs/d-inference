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
	"nhooyr.io/websocket"
)

type ownershipLostStore struct {
	store.Store
	lost chan struct{}
}

func (s ownershipLostStore) OwnershipLost() <-chan struct{} { return s.lost }

func TestQuiescenceEnumeratesProviderPendingAndCompletionWork(t *testing.T) {
	srv, _ := testServer(t)
	if snapshot := srv.Quiescence(); !snapshot.Quiescent {
		t.Fatalf("fresh server not quiescent: %+v", snapshot)
	}
	provider := srv.registry.Register("quiescence-provider", nil, &protocol.RegisterMessage{})
	provider.AddPending(&registry.PendingRequest{
		RequestID: "quiescence-request",
		ChunkCh:   make(chan string, 1), CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh: make(chan protocol.InferenceErrorMessage, 1),
	})
	snapshot := srv.Quiescence()
	if snapshot.Quiescent || snapshot.ProvidersConnected != 1 || snapshot.PendingAttempts != 1 {
		t.Fatalf("provider work missing from snapshot: %+v", snapshot)
	}
	srv.registry.Disconnect(provider.ID)

	release := make(chan struct{})
	started := make(chan struct{})
	if !srv.completions.submit(func() {
		close(started)
		<-release
	}) {
		t.Fatal("completion task rejected")
	}
	<-started
	if snapshot := srv.Quiescence(); snapshot.Quiescent || snapshot.CompletionActive != 1 {
		t.Fatalf("active completion missing from snapshot: %+v", snapshot)
	}
	close(release)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if !srv.WaitForQuiescence(ctx) {
		t.Fatalf("server did not become quiescent: %+v", srv.Quiescence())
	}
	srv.Close()
}

func TestProcessShutdownGateRejectsEveryMutationAndProviderWebSocket(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetAdminKey("test-key")
	server := httptest.NewServer(srv.Handler())
	defer server.Close()
	defer srv.Close()
	srv.BeginShutdown()

	for _, request := range []struct {
		method string
		path   string
		auth   bool
	}{
		{method: http.MethodPost, path: "/v1/device/code"},
		{method: http.MethodPost, path: "/v1/billing/stripe/webhook"},
		{method: http.MethodPost, path: "/v1/mdm/webhook"},
		{method: http.MethodGet, path: "/ws/provider"},
		{method: http.MethodGet, path: "/v1/models", auth: true},
	} {
		req, err := http.NewRequest(request.method, server.URL+request.path, nil)
		if err != nil {
			t.Fatal(err)
		}
		if request.auth {
			req.Header.Set("Authorization", "Bearer test-key")
		}
		response, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		response.Body.Close()
		if response.StatusCode != http.StatusServiceUnavailable {
			t.Errorf("%s %s status = %d, want 503",
				request.method, request.path, response.StatusCode)
		}
	}
	response, err := http.Get(server.URL + "/health")
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("health status = %d, want 200", response.StatusCode)
	}
	if inflight := srv.MutationInflight(); inflight != 0 {
		t.Fatalf("rejected mutation inflight = %d", inflight)
	}
	request, _ := http.NewRequest(
		http.MethodGet, server.URL+"/v1/admin/quiescence", nil,
	)
	request.Header.Set("Authorization", "Bearer test-key")
	quiescenceResponse, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer quiescenceResponse.Body.Close()
	if quiescenceResponse.StatusCode != http.StatusOK {
		t.Fatalf("quiescence status = %d, want 200", quiescenceResponse.StatusCode)
	}
	var snapshot QuiescenceSnapshot
	if err := json.NewDecoder(quiescenceResponse.Body).Decode(&snapshot); err != nil {
		t.Fatal(err)
	}
	if !snapshot.Quiescent {
		t.Fatalf("quiescence endpoint counted itself: %+v", snapshot)
	}
}

func TestReadinessAndQuiescenceFailClosedOnOwnershipLoss(t *testing.T) {
	srv, backing := testServer(t)
	lost := make(chan struct{})
	srv.store = ownershipLostStore{Store: backing, lost: lost}
	close(lost)
	if snapshot := srv.Quiescence(); snapshot.OwnershipHealthy || snapshot.Quiescent {
		t.Fatalf("ownership loss not reflected: %+v", snapshot)
	}
	request := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	response := httptest.NewRecorder()
	srv.handleReadyz(response, request)
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("readyz status = %d, want 503", response.Code)
	}
}

func TestExistingProviderWebSocketDoesNotBlockIngressDrain(t *testing.T) {
	srv, _ := testServer(t)
	server := httptest.NewServer(srv.Handler())
	defer server.Close()
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	connection, _, err := websocket.Dial(
		ctx,
		"ws"+strings.TrimPrefix(server.URL, "http")+"/ws/provider",
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.CloseNow()
	srv.BeginShutdown()
	drainCtx, drainCancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer drainCancel()
	if !srv.WaitForInflightZero(drainCtx) {
		t.Fatalf("provider WebSocket counted as mutating HTTP: %+v", srv.Quiescence())
	}
	srv.FenceProviderSessions()
	if !srv.WaitForProviderSessions(ctx) {
		t.Fatal("provider WebSocket did not exit after fence")
	}
}

func TestQuiescenceTracksBackgroundMutatorsUntilJoined(t *testing.T) {
	srv, _ := testServer(t)
	defer srv.Close()
	started := make(chan struct{})
	release := make(chan struct{})
	if !srv.StartBackgroundTask("test.background", func() {
		close(started)
		<-release
	}) {
		t.Fatal("background task was rejected")
	}
	<-started
	snapshot := srv.Quiescence()
	if snapshot.BackgroundTasks != 1 || snapshot.Quiescent {
		t.Fatalf("background task missing from quiescence: %+v", snapshot)
	}
	close(release)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if !srv.WaitForBackgroundTasks(ctx) {
		t.Fatal("background task did not join")
	}
	if snapshot := srv.Quiescence(); snapshot.BackgroundTasks != 0 {
		t.Fatalf("background tasks after join = %d", snapshot.BackgroundTasks)
	}
}
