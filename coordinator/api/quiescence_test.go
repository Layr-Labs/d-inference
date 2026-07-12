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
	backgroundCtx, backgroundCancel := context.WithTimeout(context.Background(), time.Second)
	defer backgroundCancel()
	if !srv.WaitForBackgroundTasks(backgroundCtx) {
		t.Fatal("shutdown background tasks did not join")
	}

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

func TestAdminHandoffFencesProvidersAndBackgroundWhileCompletionsDrain(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetAdminKey("test-key")
	server := httptest.NewServer(srv.Handler())
	defer server.Close()
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
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

	backgroundStopped := make(chan struct{})
	if !srv.StartHandoffTask("test.handoff-background", func(ctx context.Context) {
		<-ctx.Done()
		close(backgroundStopped)
	}) {
		t.Fatal("handoff background task was rejected before handoff")
	}

	completionStarted := make(chan struct{})
	releaseCompletion := make(chan struct{})
	if !srv.completions.submit(func() {
		close(completionStarted)
		<-releaseCompletion
	}) {
		t.Fatal("completion task was rejected before handoff")
	}
	<-completionStarted

	request, err := http.NewRequest(
		http.MethodPost,
		server.URL+"/v1/admin/drain",
		strings.NewReader(`{"mode":"handoff"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer test-key")
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("handoff status = %d, want 200", response.StatusCode)
	}

	select {
	case <-backgroundStopped:
	case <-ctx.Done():
		t.Fatal("Server-owned handoff context was not cancelled")
	}
	if !srv.WaitForProviderSessions(ctx) {
		t.Fatalf("provider session survived handoff: %+v", srv.Quiescence())
	}
	if snapshot := srv.Quiescence(); snapshot.CompletionOutstanding != 1 || snapshot.Quiescent {
		t.Fatalf("handoff did not preserve admitted completion work: %+v", snapshot)
	}
	if srv.StartHandoffTask("test.must-not-restart", func(context.Context) {}) {
		t.Fatal("background mutator restarted after handoff fence")
	}
	srv.SetDraining(false)
	if !srv.IsDraining() {
		t.Fatal("irreversible handoff fence was cleared")
	}

	close(releaseCompletion)
	if !srv.WaitForQuiescence(ctx) {
		t.Fatalf("handoff did not reach quiescence after completion: %+v", srv.Quiescence())
	}
}

func TestInferenceDrainLeavesProviderAndHandoffContextRunning(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetAdminKey("test-key")
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

	request, err := http.NewRequest(
		http.MethodPost,
		server.URL+"/v1/admin/drain",
		strings.NewReader(`{"draining":true}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer test-key")
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("drain status = %d, want 200", response.StatusCode)
	}
	if got := srv.providerSessionCount.Load(); got != 1 {
		t.Fatalf("normal inference drain closed provider sessions: %d", got)
	}
	select {
	case <-srv.HandoffContext().Done():
		t.Fatal("normal inference drain cancelled handoff context")
	default:
	}
}

func TestHandoffRaceCannotRestartBackgroundMutator(t *testing.T) {
	for range 50 {
		srv, _ := testServer(t)
		start := make(chan struct{})
		accepted := make(chan bool, 1)
		handoffDone := make(chan struct{})
		go func() {
			<-start
			accepted <- srv.StartHandoffTask(
				"test.racing-background",
				func(ctx context.Context) { <-ctx.Done() },
			)
		}()
		go func() {
			<-start
			srv.BeginHandoff()
			close(handoffDone)
		}()
		close(start)
		wasAccepted := <-accepted
		<-handoffDone

		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		if !srv.WaitForBackgroundTasks(ctx) {
			cancel()
			t.Fatal("background task admitted during handoff did not join")
		}
		cancel()
		if wasAccepted && srv.backgroundTaskCount.Load() != 0 {
			t.Fatal("accepted racing task survived the handoff context")
		}
		if srv.StartHandoffTask("test.restart", func(context.Context) {}) {
			t.Fatal("handoff allowed a background task restart")
		}
		srv.Close()
	}
}
