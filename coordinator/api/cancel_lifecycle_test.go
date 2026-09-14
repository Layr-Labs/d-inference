package api

import (
	"context"
	"io"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// TestSendProviderCancelMetersDeliveryFailure: a cancel that cannot be handed
// to the provider writer is no longer Debug-only — it is counted on
// inference.cancel_send_failed with a bounded reason. A provider whose writer
// is gone (disconnect race, the historical "expected case") reports
// writer_stopped through the real DogStatsD client.
func TestSendProviderCancelMetersDeliveryFailure(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{AdminKey: "k"}), ServerConfig{}, logger)
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)

	// Connected as far as the Server can tell (Conn set) but its writer has
	// been torn down: EnqueueText fails with the writer-stopped sentinel.
	p := &registry.Provider{ID: "p-dead", Conn: &websocket.Conn{}}
	if srv.inferenceAttempts().SendCancel(p, "req-1") {
		t.Fatal("sendProviderCancel must report failure when the writer is gone")
	}
	_ = dd.Statsd.Flush()
	packets := collector.drain()
	got := findMetrics(packets, attempt.MetricCancelSendFailed)
	if len(got) != 1 || !strings.Contains(got[0], "reason:writer_stopped") {
		t.Fatalf("cancel_send_failed packets = %v, want one with reason:writer_stopped", got)
	}
	for _, pk := range got {
		if strings.Contains(pk, "req-1") || strings.Contains(pk, "p-dead") {
			t.Fatalf("metric must not carry request or provider identity: %q", pk)
		}
	}

	// No socket at all is a test fixture, not a delivery failure: no metric.
	if srv.inferenceAttempts().SendCancel(&registry.Provider{ID: "p-nosock"}, "req-2") {
		t.Fatal("provider without a socket cannot succeed")
	}
	_ = dd.Statsd.Flush()
	if extra := findMetrics(collector.drain(), attempt.MetricCancelSendFailed); len(extra) != 0 {
		t.Fatalf("nil Conn must not be metered as a delivery failure: %v", extra)
	}
}

// TestCancelDispatchSkipsCancelAfterCompletionIngress pins the hedge-loser
// edge case: a racer that completed EMPTY on time is parked by handleComplete
// on the speculative empty-completion decision WITHOUT RemovePending, so its
// record is still live when cancelDispatch runs — yet the completion ingress
// proves nothing is running. No cancel, no cancel_sent, no zombie entry. A
// racer with no terminal at all still gets its cancel recorded; this fixture
// has no socket, so nothing is handed to a writer and cancel_sent stays at
// zero (delivery counting is pinned in TestCancelSendCountsOnlyDeliveredFrames).
func TestCancelDispatchSkipsCancelAfterCompletionIngress(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	srv := NewServer(reg, store.NewMemory(store.Config{AdminKey: "k"}), ServerConfig{}, logger)
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)
	model := "hedge-empty-model"
	provider := makeRoutableProvider(t, reg, "p1", model)
	newPending := func(id string) *registry.PendingRequest {
		pr := &registry.PendingRequest{
			RequestID:  id,
			Model:      model,
			ChunkCh:    make(chan registry.ProviderChunk, 1),
			CompleteCh: make(chan protocol.UsageInfo, 1),
			ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
		}
		provider.AddPending(pr)
		return pr
	}

	finished := newPending("req-finished-empty")
	finished.MarkCompletionIngress(time.Now())
	srv.inferenceAttempts().Cancel(provider, finished, attempt.CancelCauseHedgeLoser)
	if provider.GetPending(finished.RequestID) != nil {
		t.Fatal("cancelDispatch must still remove the pending record")
	}
	if e, ok := srv.inferenceAttempts().ResolveCancelledTerminal(finished.RequestID, attempt.CancelTerminalComplete, attempt.CancelledOutcomeCompletePartial, time.Now()); ok {
		t.Fatalf("a racer that already completed must not be tracked as a zombie: %+v", e)
	}
	_ = dd.Statsd.Flush()
	if got := findMetrics(collector.drain(), attempt.MetricCancelSent); len(got) != 0 {
		t.Fatalf("cancel_sent must not fire for a racer whose completion was ingressed: %v", got)
	}

	running := newPending("req-still-running")
	srv.inferenceAttempts().Cancel(provider, running, attempt.CancelCauseHedgeLoser)
	if _, ok := srv.inferenceAttempts().ResolveCancelledTerminal(running.RequestID, attempt.CancelTerminalComplete, attempt.CancelledOutcomeCompletePartial, time.Now()); !ok {
		t.Fatal("a still-running racer must be tracked for terminal correlation")
	}
	_ = dd.Statsd.Flush()
	if got := findMetrics(collector.drain(), attempt.MetricCancelSent); len(got) != 0 {
		t.Fatalf("no socket, no frame handed over: cancel_sent must not fire, got %v", got)
	}
}

// TestCancelSendCountsOnlyDeliveredFrames pins the delivery semantics of the
// cancel lifecycle telemetry. A cancel whose enqueue fails (writer stopped /
// control lane full) is recorded but neither marked nor counted on
// inference.cancel_sent; a terminal for it is correlated (so the caller does
// not log it as unknown) but reported as cancelled_terminal{delivered:false}
// with no cancel_to_terminal_ms sample. The next stray chunk retries; the
// first cancel that reaches a writer counts cancel_sent exactly once, under
// the abandon path's cause, and a terminal after it is delivered:true with a
// latency sample. A live provider whose first send succeeds is counted at once.
func TestCancelSendCountsOnlyDeliveredFrames(t *testing.T) {
	srv, reg, _, ts := setupTestServer(t)
	defer ts.Close()
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	const model = "cancel-delivery-model"
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{{ID: model, ModelType: "chat"}}, "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=")
	defer conn.Close(websocket.StatusNormalClosure, "")
	ids := reg.ProviderIDs()
	if len(ids) != 1 {
		t.Fatalf("registered providers = %v, want exactly one", ids)
	}
	live := reg.GetProvider(ids[0])
	dead := &registry.Provider{ID: "p-dead", Conn: &websocket.Conn{}}
	drain := func() []string {
		_ = dd.Statsd.Flush()
		return collector.drain()
	}

	// Enqueue fails: recorded, unsent, not counted.
	t0 := time.Now()
	srv.inferenceAttempts().SendAbandonCancel(dead, "req-fail", model, attempt.CancelCauseClientGonePost)
	packets := drain()
	if got := findMetrics(packets, attempt.MetricCancelSent); len(got) != 0 {
		t.Fatalf("a failed enqueue must not count as sent: %v", got)
	}
	requireMetricWithTags(t, packets, attempt.MetricCancelSendFailed, "reason:writer_stopped")
	// The provider finishes on its own: correlated, but no cancel was delivered.
	e, ok := srv.inferenceAttempts().ResolveCancelledTerminal("req-fail", attempt.CancelTerminalComplete, attempt.CancelledOutcomeCompletePartial, t0.Add(time.Second))
	if !ok || e.Deliveries() != 0 {
		t.Fatalf("terminal correlation = (%+v, %v), want the unsent entry", e, ok)
	}
	if e.Deliveries() != 0 || e.Cause() != attempt.CancelCauseClientGonePost {
		t.Fatalf("entry after failed send = %+v, want sent=0 with the abandon cause", e)
	}
	packets = drain()
	if got := findMetrics(packets, attempt.MetricCancelToTerminalMs); len(got) != 0 {
		t.Fatalf("no cancel reached the provider, so no cancel→terminal latency: %v", got)
	}
	requireMetricWithTags(t, packets, attempt.MetricCancelledTerminal,
		"outcome:"+attempt.CancelledOutcomeCompletePartial, "cause:"+attempt.CancelCauseClientGonePost, "delivered:false")

	// Enqueue fails, then a stray chunk retries on a writer that accepts: the
	// first DELIVERED cancel counts cancel_sent once under the abandon cause.
	srv.inferenceAttempts().SendAbandonCancel(dead, "req-retry", model, attempt.CancelCauseFirstChunkTimeout)
	packets = drain()
	if got := findMetrics(packets, attempt.MetricCancelSent); len(got) != 0 {
		t.Fatalf("a failed enqueue must not count as sent: %v", got)
	}
	// Exercise the existing 250 ms retry policy through the stray-frame path.
	srv.inferenceAttempts().StrayChunk(live, live.ID, "req-retry", time.Now().Add(250*time.Millisecond))
	packets = drain()
	requireMetricWithTags(t, packets, attempt.MetricCancelSent, "cause:"+attempt.CancelCauseFirstChunkTimeout, "model:"+model)
	requireMetricWithTags(t, packets, attempt.MetricZombieStreamCancel, "resend_index:0")
	e, ok = srv.inferenceAttempts().ResolveCancelledTerminal("req-retry", attempt.CancelTerminalError, attempt.CancelledOutcomeErrorCancelled, time.Now())
	if !ok {
		t.Fatal("delivered retry must still correlate its terminal")
	}
	if e.Deliveries() != 1 {
		t.Fatalf("entry after the delivered retry = %+v, want sent=1", e)
	}
	packets = drain()
	requireMetricWithTags(t, packets, attempt.MetricCancelToTerminalMs, "terminal:"+attempt.CancelTerminalError, "cause:"+attempt.CancelCauseFirstChunkTimeout)
	requireMetricWithTags(t, packets, attempt.MetricCancelledTerminal,
		"outcome:"+attempt.CancelledOutcomeErrorCancelled, "cause:"+attempt.CancelCauseFirstChunkTimeout, "delivered:true")

	// A stray chunk can win the initial enqueue while the abandon path is
	// releasing registry capacity. Its later send is a resend, not another
	// first cancel for this request.
	srv.inferenceAttempts().RecordAbandon("req-stray-first", model, attempt.CancelCauseClientGonePre, time.Now())
	srv.inferenceAttempts().StrayChunk(live, live.ID, "req-stray-first", time.Now())
	srv.inferenceAttempts().SendRecordedCancel(live, "req-stray-first", model, attempt.CancelCauseClientGonePre)
	packets = drain()
	if got := sumMetric(t, packets, attempt.MetricCancelSent, "cause:"+attempt.CancelCauseClientGonePre, "model:"+model); got != 1 {
		t.Fatalf("a stray-first race must count one initial cancel, got %v: %v", got, packets)
	}

	// A live writer: counted on the first send, exactly once.
	srv.inferenceAttempts().SendAbandonCancel(live, "req-live", model, attempt.CancelCauseHedgeLoser)
	packets = drain()
	if got := requireMetricWithTags(t, packets, attempt.MetricCancelSent, "cause:"+attempt.CancelCauseHedgeLoser, "model:"+model); len(got) != 1 {
		t.Fatalf("cancel_sent for a delivered first send = %v, want exactly one", got)
	}
	e, ok = srv.inferenceAttempts().ResolveCancelledTerminal("req-live", attempt.CancelTerminalComplete, attempt.CancelledOutcomeCompletePartial, time.Now())
	if !ok || e.Deliveries() != 1 {
		t.Fatalf("entry after a delivered first send = %+v, want sent=1", e)
	}
}

// TestUnknownTerminalPathsOnBareServer: the unknown-request branches of the
// provider frame handlers now consult the zombie tracker. A Server built as a
// bare literal (no canceller, no Datadog, no settlement holder — the shape
// many unit tests use) and a canceller literal with nil maps must both take
// those branches without panicking.
func TestUnknownTerminalPathsOnBareServer(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	for name, srv := range map[string]*Server{
		"nil canceller":     {registry: reg, logger: logger},
		"literal canceller": {registry: reg, logger: logger, attemptTracker: &attempt.Tracker{}},
	} {
		t.Run(name, func(t *testing.T) {
			provider := &registry.Provider{ID: "p-bare"}
			const unknownID = "never-dispatched"
			srv.handleChunk("p-bare", provider, &protocol.InferenceResponseChunkMessage{
				Type: protocol.TypeInferenceResponseChunk, RequestID: unknownID,
			})
			srv.handleInferenceError("p-bare", provider, &protocol.InferenceErrorMessage{
				Type: protocol.TypeInferenceError, RequestID: unknownID,
				Error: "boom", StatusCode: 500,
			})
			srv.handleCompleteAt("p-bare", provider, &protocol.InferenceCompleteMessage{
				Type: protocol.TypeInferenceComplete, RequestID: unknownID,
			}, time.Now())
			// A second chunk for the same id exercises the re-send path too.
			srv.handleChunk("p-bare", provider, &protocol.InferenceResponseChunkMessage{
				Type: protocol.TypeInferenceResponseChunk, RequestID: unknownID,
			})
		})
	}
}
