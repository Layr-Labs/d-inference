package api

import (
	"log/slog"
	"net/http"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// deadlineWedgeThreshold mirrors registry.deadlineWedgeThreshold.
const deadlineWedgeThreshold = 5

// wedgeQualifyingRequest is a primary-attempt pending request the wedge
// tracker's discriminators accept: short prompt, empty slot, a full
// first-content clock attached at dispatch.
func wedgeQualifyingRequest(name, model string) *registry.PendingRequest {
	now := time.Now()
	return &registry.PendingRequest{
		RequestID:             "req-" + name,
		Model:                 model,
		EstimatedPromptTokens: 100,
		Timing:                &registry.RequestTiming{ReceivedAt: now},
		FirstContentDeadline:  now.Add(9 * time.Second),
		FirstContentBudgetMS:  8_950,
	}
}

// TestDeadlineWedgeIgnoresCoordinatorLateContentConversions: the
// coordinator's own deadline_unreachable conversions of ADMITTED attempts
// (first content or a clean empty completion after the request-absolute
// deadline, stamped CoordinatorCauseDeadlineLateContent in provider.go)
// reach the same dispatch funnel as an engine refusal. They must not advance
// a wedge run: the engine accepted the request, so the terminal indicts the
// clock, not the slot. Fails before the fix (the hook keyed on error_reason
// alone and armed the pair on five conversions).
func TestDeadlineWedgeIgnoresCoordinatorLateContentConversions(t *testing.T) {
	srv, reg, provider, _ := newBreakerExemptionHarness(t, "wedge-late-content")
	reg.SetDeadlineWedgeSkipEnabled(true)
	d := &dispatchState{s: srv, model: "test-model"}
	conversion := protocol.InferenceErrorMessage{
		Type:             protocol.TypeInferenceError,
		StatusCode:       http.StatusServiceUnavailable,
		Error:            "first content was unavailable at the request deadline",
		ErrorReason:      errorReasonDeadlineUnreachable,
		FailureCode:      protocol.FailureCodeCapacity,
		CoordinatorCause: protocol.CoordinatorCauseDeadlineLateContent,
	}
	for i := 0; i < 2*deadlineWedgeThreshold; i++ {
		pr := wedgeQualifyingRequest("late", "test-model")
		d.noteDispatchRetry(provider, pr, conversion, nil)
	}
	if reg.DeadlineWedgeSkipActive(provider.ID, "test-model") {
		t.Fatal("coordinator-synthesized late-content conversions armed the deadline-wedge skip")
	}
	if st := reg.DeadlineWedgeStats(); st.ArmedPairs != 0 {
		t.Fatalf("stats after conversions = %+v, want no armed pair", st)
	}

	// Control: the provider's own typed refusal (no coordinator cause) still
	// counts and arms at the threshold through the same funnel.
	refusal := conversion
	refusal.CoordinatorCause = ""
	refusal.Error = "untrusted provider detail"
	for i := 0; i < deadlineWedgeThreshold; i++ {
		d.noteDispatchRetry(provider, wedgeQualifyingRequest("refused", "test-model"), refusal, nil)
	}
	if !reg.DeadlineWedgeSkipActive(provider.ID, "test-model") {
		t.Fatal("provider-originated refusals must still arm the skip at the threshold")
	}
}

// TestLateFirstContentConversionIsCoordinatorCaused drives the real
// late-first-content branch of handleChunk (real decrypt path, real e2e
// keys): first content decrypted after the request-absolute deadline becomes
// the deadline_unreachable capacity terminal AND carries the coordinator-only
// cause through the ingress sanitizer onto the frame the dispatch loop reads.
// Fails before the fix twice over: the branch stamped no cause, and the
// sanitizer rebuilt the safe frame without one.
func TestLateFirstContentConversionIsCoordinatorCaused(t *testing.T) {
	key := testPublicKeyB64()
	f := newImplicitKeyFixture(t, key, key)
	f.pr.FirstContentDeadline = time.Now().Add(-time.Second)
	chunk := f.sealed(t, `data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"late"}}]}`, key)
	f.srv.handleChunk(f.provider.ID, f.provider, &chunk)
	assertLateContentConversion(t, f.pr)
}

// TestLateEmptyCompletionConversionIsCoordinatorCaused drives the second
// site: a clean completion with no first content after the deadline
// (handleCompleteAt) is converted the same way and carries the same cause.
func TestLateEmptyCompletionConversionIsCoordinatorCaused(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	srv := NewServer(reg, store.NewMemory(store.Config{AdminKey: "test-key"}), ServerConfig{}, logger)
	provider := reg.Register("provider-late-complete", nil, &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:  "mlx-swift",
	})
	pr := &registry.PendingRequest{
		RequestID:            "req-late-complete",
		Model:                "test-model",
		FirstContentDeadline: time.Now().Add(-time.Second),
		ChunkCh:              make(chan registry.ProviderChunk, 1),
		CompleteCh:           make(chan protocol.UsageInfo, 1),
		ErrorCh:              make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)
	srv.handleCompleteAt(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage:     protocol.UsageInfo{PromptTokens: 5},
	}, time.Now())
	assertLateContentConversion(t, pr)
}

func assertLateContentConversion(t *testing.T, pr *registry.PendingRequest) {
	t.Helper()
	// The conversion sends the terminal on ErrorCh and then closes every
	// channel, so ErrorCh is read first (a closed ErrorCh means the late frame
	// was accepted as a completion / delivered as content instead).
	select {
	case errMsg, ok := <-pr.ErrorCh:
		if !ok {
			t.Fatal("error channel closed without a terminal: the late frame was accepted, want the deadline conversion")
		}
		if errMsg.ErrorReason != errorReasonDeadlineUnreachable || errMsg.FailureCode != protocol.FailureCodeCapacity {
			t.Fatalf("terminal = %+v, want the deadline_unreachable capacity conversion", errMsg)
		}
		if errMsg.CoordinatorCause != protocol.CoordinatorCauseDeadlineLateContent {
			t.Fatalf("CoordinatorCause = %q, want %q on the coordinator's own conversion", errMsg.CoordinatorCause, protocol.CoordinatorCauseDeadlineLateContent)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for the deadline conversion terminal (was the late frame accepted?)")
	}
}
