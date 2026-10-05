package inference_test

import (
	"encoding/json"
	"log/slog"
	"os"
	"testing"
	"time"

	routeoutcome "github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func newProfilerTestServer(t *testing.T) *serverFixture {
	t.Helper()
	t.Setenv("EIGENINFERENCE_PROFILE_SAMPLE_RATE", "1")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	srv := newComposedServer(registry.New(logger), memory.NewMemory(store.Config{}), TestServerConfig{AdminKey: "admin-test-key"}, logger)
	t.Cleanup(srv.Close)
	return srv
}

func containsKey(b []byte, key string) bool {
	var m map[string]any
	if json.Unmarshal(b, &m) != nil {
		return false
	}
	_, ok := m[key]
	return ok
}

// TestClaimedCompleteFrameFinalizesAfterPendingRemoved pins the ownership
// window opened by the terminal claim. A completion frame claims the attempt's
// terminal at ingress; a consumer-side non-terminal remover (client-gone
// cancelDispatch, releaseUnsentDispatch, registry.Disconnect) removes the
// pending request before the frame's own RemovePending, so the frame returns
// through the unknown-request path — directly, or via handleInferenceError on
// the deadline-late branch. Once claimed, neither the route-outcome funnel
// (it skips CompleteTerminal for a claimed attempt) nor the no-terminal
// fallback finishes the record, so the frame must close its own claim on
// those returns (provider_outcome=completed) or the attempt never finalizes.
// claimFixture is one in-flight, dispatched attempt whose provider completion
// the claim-window tests drive by hand: a registered (nil-conn) provider, a
// pending request with a profile, and a finalize callback that captures the
// record the sink would build.
type claimFixture struct {
	srv      *serverFixture
	provider *registry.Provider
	pr       *registry.PendingRequest
	ap       *registry.AttemptProfile
}

// claimTestProfile is the profile the completion frame carries; prompt_tokens
// matches the frame's usage so the row's consistency flag is true.
const claimTestProfile = `{"schema":1,"total_us":1000,"prompt_tokens":100}`

func newClaimFixture(t *testing.T, id string, deadline time.Time, reserved int64) claimFixture {
	t.Helper()
	return newClaimFixtureOn(t, newProfilerTestServer(t), id, deadline, reserved)
}

// newClaimFixtureOn is newClaimFixture on an existing server: a fresh
// provider, pending request and attempt per call.
func newClaimFixtureOn(t *testing.T, srv *serverFixture, id string, deadline time.Time, reserved int64) claimFixture {
	t.Helper()
	provider := srv.registry.Register(id, nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: "m", ModelType: "chat", Quantization: "4bit"}},
	})
	pr := &registry.PendingRequest{
		RequestID:            id,
		Model:                "m",
		ConsumerKey:          testConsumerID,
		ReservedMicroUSD:     reserved,
		FirstContentDeadline: deadline,
		ChunkCh:              make(chan registry.ProviderChunk, 1),
		CompleteCh:           make(chan protocol.UsageInfo, 1),
		ErrorCh:              make(chan protocol.InferenceErrorMessage, 1),
	}
	rp := observedTestProfile(t, srv, time.Now(), "coord-"+id)
	ap := rp.NewAttempt(id, 0, "")
	ap.ProviderID = provider.ID
	ap.Mark(registry.StampWriteSubmitted)
	ap.Mark(registry.StampWriteDone)
	pr.Profile = ap
	provider.AddPending(pr)
	return claimFixture{srv: srv, provider: provider, pr: pr, ap: ap}
}

// runClaimFrame delivers the provider's completion for requestID (the id the
// pending request was registered under) off the test goroutine, as the read
// loop does.
func runClaimFrame(f claimFixture, requestID string) chan struct{} {
	done := make(chan struct{})
	go func() {
		f.srv.HandleCompleteAt(f.provider.ID, f.provider, &protocol.InferenceCompleteMessage{
			Type:      protocol.TypeInferenceComplete,
			RequestID: requestID,
			Usage:     protocol.UsageInfo{PromptTokens: 100},
			Profile:   []byte(claimTestProfile),
		}, time.Now())
		close(done)
	}()
	return done
}

// awaitClaimed blocks until the completion frame has claimed the terminal and
// retained its profile. The ingress signal fires before the claim, and the
// retained profile is the frame's last write before it parks on arbitration,
// so this puts the frame deterministically inside the window (claimed, not
// yet settled).
func awaitClaimed(t *testing.T, f claimFixture) {
	t.Helper()
	<-f.pr.CompletionIngressSignal()
	waitForAdaptiveCondition(t, 2*time.Second, func() bool {
		raw, _ := f.ap.ProviderProfileRaw()
		return f.ap.TerminalClaimed() && raw != nil
	})
}

func awaitClosed(t *testing.T, ch <-chan struct{}, what string) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(2 * time.Second):
		t.Fatal(what)
	}
}

// awaitClaimRecord lands the handler half and returns the finalized record;
// the attempt must not have finalized on the terminal half alone.
func awaitClaimRecord(t *testing.T, f claimFixture) *store.RequestProfileRecord {
	t.Helper()
	if f.ap.Finalized() {
		t.Fatal("attempt finalized before the handler half landed")
	}
	f.ap.CompleteHandler()
	return awaitPersistedProfile(t, f.srv, f.ap)
}

// assertClaimRow checks a completed provider outcome, the funnel's
// status/reason and a retained, consistent profile.
func assertClaimRow(t *testing.T, rec *store.RequestProfileRecord, want *store.InferenceRouteOutcome) {
	t.Helper()
	if rec.ProviderOutcome != "completed" || rec.FinalStatus != want.FinalStatus || rec.ErrorReason != routeoutcome.ProfileErrorReason(want) {
		t.Fatalf("row = %q/%q/%q, want completed/%s/%s", rec.ProviderOutcome, rec.FinalStatus, rec.ErrorReason, want.FinalStatus, routeoutcome.ProfileErrorReason(want))
	}
	if !rec.ProviderProfileValid || rec.ProviderProfileInvalidReason != "" || rec.ProviderProfileConsistent == nil || !*rec.ProviderProfileConsistent {
		t.Fatalf("profile sent with the completion must be retained: valid=%v reason=%q consistent=%v",
			rec.ProviderProfileValid, rec.ProviderProfileInvalidReason, rec.ProviderProfileConsistent)
	}
}
