package api

// R1 integration tests: a provider that closes its socket GRACEFULLY
// (WebSocket 1000/1001 — stop / restart / update) with requests in flight must
// not be booked as sick. The requests still fail over invisibly (pre-content)
// or surface an in-band error (post-commit), exactly like an abrupt drop, but
// the flushed 502s strike none of the stable-identity health trackers. An
// abrupt drop (CloseNow) keeps striking — that is the reconnecting-zombie
// discriminator. A reconnect on a NEWER binary version then clears the
// disconnect-flush strikes an abrupt death left behind; the same version does
// not (registry/version_reset.go).
//
// Same live harness as failover_integration_test.go: real coordinator
// (httptest + in-memory store + real registry), fake providers speaking the
// full encrypted WS protocol.

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"nhooyr.io/websocket"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// closeGoingAway sends a graceful 1001 going-away close — what
// CoordinatorClient.shutdown() emits on the provider's run() shutdown path.
func (fp *failoverProvider) closeGoingAway() {
	fp.closeOnce.Do(func() {
		_ = fp.conn.Close(websocket.StatusGoingAway, "restarting")
	})
}

// bindRestartTestIdentity binds a fake provider's live session to a serial
// identity so the flushed 502s land on (and can be queried through) the
// stable fault key rather than the session UUID.
func bindRestartTestIdentity(t *testing.T, reg *registry.Registry, fp *failoverProvider, serial string) string {
	t.Helper()
	p := reg.GetProvider(fp.registryID)
	if p == nil {
		t.Fatalf("provider %s not registered", fp.name)
	}
	p.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: serial})
	return "serial:" + serial
}

// awaitCondition polls cond until it holds or timeout elapses.
func awaitCondition(t *testing.T, timeout time.Duration, cond func() bool, what string) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// holdThenCloseScript sends the boilerplate role chunk for every dispatch and
// holds the request open; when the closeAt-th dispatch arrives it closes the
// socket — gracefully (1001) or abruptly (CloseNow) — with every held request
// still pre-content.
func holdThenCloseScript(model string, closeAt int, graceful bool) inferenceScript {
	return func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		fp.sendRoleChunk(ctx, req, model)
		if fp.dispatchCount() < closeAt {
			return
		}
		time.Sleep(40 * time.Millisecond)
		if graceful {
			fp.closeGoingAway()
		} else {
			fp.closeNow()
		}
	}
}

// runRestartDisconnectScenario dispatches inFlight streaming requests to the
// fast provider A (one at a time, waiting for each dispatch to land so the
// cost scheduler cannot spill one onto B), lets A's script close the socket on
// the last one, and returns the consumer results plus A's stable identity.
func runRestartDisconnectScenario(t *testing.T, ctx context.Context, model string, inFlight int, graceful bool, serial string) (reg *registry.Registry, srv *httptest.Server, pA, pB *failoverProvider, stableID string, statuses []int, bodies []string) {
	t.Helper()
	reg, _, srv = setupFailoverServer(t)
	pA = startFailoverProvider(t, ctx, srv, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.9.0", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: holdThenCloseScript(model, inFlight, graceful),
	})
	pB = startFailoverProvider(t, ctx, srv, reg, failoverProviderConfig{
		Name: "provider-b", Version: "0.9.0", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
	})
	stableID = bindRestartTestIdentity(t, reg, pA, serial)

	statuses = make([]int, inFlight)
	bodies = make([]string, inFlight)
	var wg sync.WaitGroup
	for i := 0; i < inFlight; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			status, body, err := postChat(ctx, srv.URL, "test-key", buildChatBody(t, model, true, nil))
			if err != nil {
				t.Errorf("request %d: %v", i, err)
				return
			}
			statuses[i], bodies[i] = status, body
		}(i)
		want := i + 1
		awaitCondition(t, 5*time.Second, func() bool { return pA.dispatchCount() >= want }, "dispatch to provider-a")
	}
	wg.Wait()
	return reg, srv, pA, pB, stableID, statuses, bodies
}

// TestRestartDisconnect_GracefulCloseIsHealthNeutral: three pre-content
// requests in flight on A when it closes with 1001. All three fail over to B
// invisibly, and A's identity carries NO inference-error cooldown and NO open
// node breaker afterwards (three 502 flush strikes would have tripped the
// 2-strike cooldown — see the abrupt sibling below).
func TestRestartDisconnect_GracefulCloseIsHealthNeutral(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	model := "restart-graceful-model"

	reg, _, pA, pB, stableID, statuses, bodies := runRestartDisconnectScenario(t, ctx, model, 3, true, "SER-GRACEFUL")

	for i := range statuses {
		assertCleanFailoverStream(t, statuses[i], bodies[i], markerFor("provider-b"))
	}
	if got := pB.dispatchCount(); got != 3 {
		t.Errorf("provider-b dispatches = %d, want 3 (every held request retried on B)", got)
	}
	if got := pA.dispatchCount(); got != 3 {
		t.Errorf("provider-a dispatches = %d, want 3", got)
	}
	if reg.InferenceErrorCooldownActive(stableID, model, "base") {
		t.Errorf("graceful close: inference-error cooldown ACTIVE for %s — the restart flush struck the identity", stableID)
	}
	if reg.ProviderBreakerOpen(stableID) {
		t.Errorf("graceful close: node breaker OPEN for %s", stableID)
	}
	if reg.HealthEjectionOpen(stableID) {
		t.Errorf("graceful close: identity %s ejected", stableID)
	}
}

// TestRestartDisconnect_AbruptCloseStillStrikes: the same three in-flight
// requests, but A drops the socket without a close frame. The requests still
// fail over to B, and the flush DOES strike: the (identity, model, shape)
// inference-error cooldown is active — the zombie discriminator is intact.
func TestRestartDisconnect_AbruptCloseStillStrikes(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	model := "restart-abrupt-model"

	reg, _, _, pB, stableID, statuses, bodies := runRestartDisconnectScenario(t, ctx, model, 3, false, "SER-ABRUPT")

	for i := range statuses {
		assertCleanFailoverStream(t, statuses[i], bodies[i], markerFor("provider-b"))
	}
	if got := pB.dispatchCount(); got != 3 {
		t.Errorf("provider-b dispatches = %d, want 3", got)
	}
	awaitCondition(t, 5*time.Second, func() bool {
		return reg.InferenceErrorCooldownActive(stableID, model, "base")
	}, "inference-error cooldown after an abrupt drop with in-flight work")
}

// TestRestartDisconnect_PostCommitStreamStillGetsInBandError: content has
// already flowed to two consumers when A closes gracefully. Both streams must
// surface the in-band "provider disconnected" error (no silent retry — B gets
// nothing), and the two post-commit flush terminals still strike nothing.
func TestRestartDisconnect_PostCommitStreamStillGetsInBandError(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	model := "restart-post-commit-model"
	const partial = "partial-before-restart"

	script := func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		fp.sendRoleChunk(ctx, req, model)
		fp.sendContentChunk(ctx, req, model, partial)
		if fp.dispatchCount() < 2 {
			return
		}
		time.Sleep(60 * time.Millisecond)
		fp.closeGoingAway()
	}
	pA := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.9.0", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})
	pB := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-b", Version: "0.9.0", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
	})
	stableID := bindRestartTestIdentity(t, reg, pA, "SER-POST-COMMIT")

	statuses := make([]int, 2)
	bodies := make([]string, 2)
	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
			if err != nil {
				t.Errorf("request %d: %v", i, err)
				return
			}
			statuses[i], bodies[i] = status, body
		}(i)
		want := i + 1
		awaitCondition(t, 5*time.Second, func() bool { return pA.dispatchCount() >= want }, "dispatch to provider-a")
	}
	wg.Wait()

	for i := range statuses {
		if statuses[i] != http.StatusOK {
			t.Errorf("request %d: status = %d, want 200 (committed by content); body = %s", i, statuses[i], bodies[i])
		}
		if !strings.Contains(bodies[i], partial) {
			t.Errorf("request %d: stream missing the pre-restart content; body = %s", i, bodies[i])
		}
		if !strings.Contains(bodies[i], `"provider_error"`) || !strings.Contains(bodies[i], "provider disconnected") {
			t.Errorf("request %d: post-commit restart did not surface the in-band provider-disconnected error; body = %s", i, bodies[i])
		}
		if strings.Contains(bodies[i], markerFor("provider-b")) {
			t.Errorf("request %d: coordinator retried on provider-b AFTER content had flowed; body = %s", i, bodies[i])
		}
	}
	if got := pB.dispatchCount(); got != 0 {
		t.Errorf("provider-b dispatches = %d, want 0", got)
	}
	if reg.InferenceErrorCooldownActive(stableID, model, "base") {
		t.Errorf("post-commit graceful close struck the identity's inference-error cooldown")
	}
	if reg.ProviderBreakerOpen(stableID) {
		t.Errorf("post-commit graceful close opened the node breaker")
	}
}

// TestVersionChangedReconnect_ClearsAbruptFlushStrikes: A dies abruptly with
// three in-flight requests (cooldown trips on its serial), then a session
// with the SAME serial registers on a NEWER version — the cooldown is gone.
// The sibling with the SAME version keeps it.
func TestVersionChangedReconnect_ClearsAbruptFlushStrikes(t *testing.T) {
	for _, tc := range []struct {
		name         string
		reconnectVer string
		wantCooldown bool
	}{
		{"newer version clears", "0.9.1", false},
		{"same version retains", "0.9.0", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			model := "restart-version-model"
			serial := "SER-VERSION-" + strings.ReplaceAll(tc.reconnectVer, ".", "-")

			reg, srv, _, _, stableID, statuses, bodies := runRestartDisconnectScenario(t, ctx, model, 3, false, serial)
			for i := range statuses {
				assertCleanFailoverStream(t, statuses[i], bodies[i], markerFor("provider-b"))
			}
			awaitCondition(t, 5*time.Second, func() bool {
				return reg.InferenceErrorCooldownActive(stableID, model, "base")
			}, "cooldown after the abrupt drop")

			// The upgraded box comes back: a fresh session on the same
			// coordinator, same serial. The registration path stores the
			// version BEFORE the test binds the identity, so
			// bindStableFaultKey is the seam exercised here.
			pA2 := startFailoverProvider(t, ctx, srv, reg, failoverProviderConfig{
				Name: "provider-a2", Version: tc.reconnectVer, DecodeTPS: 200,
				Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
			})
			bindRestartTestIdentity(t, reg, pA2, serial)

			if got := reg.InferenceErrorCooldownActive(pA2.registryID, model, "base"); got != tc.wantCooldown {
				t.Errorf("cooldown via the new session = %v, want %v", got, tc.wantCooldown)
			}
			if got := reg.InferenceErrorCooldownActive(stableID, model, "base"); got != tc.wantCooldown {
				t.Errorf("cooldown via the stable id = %v, want %v", got, tc.wantCooldown)
			}
		})
	}
}

// TestVersionChangedReconnect_LateFlushStrikesAreSuperseded: the flush 502s of
// an abruptly dropped session are recorded by the request goroutines that
// drain its ErrorCh, so they can reach noteInferenceError AFTER the identity's
// version-changed reset — registration evicts a same-serial predecessor
// (DisconnectDuplicatesBySerial) and stores the new version on the same
// goroutine, ahead of those consumers. The reset then ran against empty
// windows and consumed its interval; without the discard the late strikes
// would quarantine the NEW binary for the old one's death. Every tracker must
// stay closed for the new session, while the strikes of a session that died
// under an unchanged version, or after the reset (a throttled third version
// stamps no new reset), still land.
func TestVersionChangedReconnect_LateFlushStrikesAreSuperseded(t *testing.T) {
	const (
		serial = "SER-LATE-FLUSH"
		stable = "serial:" + serial
		model  = "late-flush-model"
	)
	bind := func(t *testing.T, reg *registry.Registry, id, version string) {
		t.Helper()
		p := makeRoutableProvider(t, reg, id, model)
		// Registration order: attestation binds the identity, then the api
		// stores the version (the seam that runs the reset).
		p.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: serial})
		p.SetVersion(version)
	}
	// dropAbruptly parks work on the session and drops it without a close
	// frame: the flush is now in the consumer's ErrorCh, not yet recorded.
	dropAbruptly := func(t *testing.T, reg *registry.Registry, id string) {
		t.Helper()
		p := reg.GetProvider(id)
		if p == nil {
			t.Fatalf("provider %s not registered", id)
		}
		p.AddPending(&registry.PendingRequest{
			RequestID:  id + "-req",
			Model:      model,
			ProviderID: id,
			ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
		})
		reg.DisconnectWithReason(id, registry.DisconnectReasonReadError)
	}
	// feedFlush plays the consumers' recording of the flushed 502s through
	// the breaker chokepoint: enough for the inference-error cooldown (2), the
	// node breaker (5) and the identity ejection (8).
	feedFlush := func(srv *Server, id string) {
		pr := &registry.PendingRequest{RequestID: id + "-req", Model: model, ProviderID: id}
		for i := 0; i < 8; i++ {
			srv.noteInferenceError(id, pr, 502, "provider disconnected", "", "")
		}
	}
	quarantined := func(t *testing.T, reg *registry.Registry, liveID string, want bool) {
		t.Helper()
		if got := reg.InferenceErrorCooldownActive(liveID, model, "base"); got != want {
			t.Errorf("InferenceErrorCooldownActive(%s) = %v, want %v", liveID, got, want)
		}
		if got := reg.ProviderBreakerOpen(liveID); got != want {
			t.Errorf("ProviderBreakerOpen(%s) = %v, want %v", liveID, got, want)
		}
		if got := reg.HealthEjectionOpen(stable); got != want {
			t.Errorf("HealthEjectionOpen(%s) = %v, want %v", stable, got, want)
		}
	}

	t.Run("flush recorded after the version reset is discarded", func(t *testing.T) {
		srv, reg, _, ts := setupTestServer(t)
		defer ts.Close()
		bind(t, reg, "s1", "0.9.0")
		dropAbruptly(t, reg, "s1")
		bind(t, reg, "s2", "0.9.1") // reset runs here, against empty windows
		feedFlush(srv, "s1")        // the consumers catch up afterwards
		quarantined(t, reg, "s2", false)
	})

	t.Run("same version keeps striking", func(t *testing.T) {
		srv, reg, _, ts := setupTestServer(t)
		defer ts.Close()
		bind(t, reg, "s1", "0.9.0")
		dropAbruptly(t, reg, "s1")
		bind(t, reg, "s2", "0.9.0") // the zombie signature: no reset
		feedFlush(srv, "s1")
		quarantined(t, reg, "s2", true)
	})

	t.Run("a drop after the reset still strikes even when the next version change is throttled", func(t *testing.T) {
		srv, reg, _, ts := setupTestServer(t)
		defer ts.Close()
		bind(t, reg, "s1", "0.9.0")
		dropAbruptly(t, reg, "s1")
		bind(t, reg, "s2", "0.9.1")
		feedFlush(srv, "s1")
		quarantined(t, reg, "s2", false)

		dropAbruptly(t, reg, "s2")
		bind(t, reg, "s3", "0.9.2") // inside the interval: throttled, no new reset
		feedFlush(srv, "s2")
		quarantined(t, reg, "s3", true)
	})
}
