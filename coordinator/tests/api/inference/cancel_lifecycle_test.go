package inference_test

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/inference"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	cancellation "github.com/eigeninference/d-inference/coordinator/internal/inference/cancellation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"nhooyr.io/websocket"
)

func TestCancelSendFailureReason(t *testing.T) {
	cases := []struct {
		err  error
		want string
	}{
		{registry.ErrProviderWriterQueueFull, "queue_full"},
		{registry.ErrProviderWriterStopped, "writer_stopped"},
		{context.DeadlineExceeded, "ctx"},
		{context.Canceled, "ctx"},
		{errors.New("boom"), "other"},
	}
	for _, c := range cases {
		if got := cancellation.SendFailureReason(c.err); got != c.want {
			t.Errorf("cancelSendFailureReason(%v) = %q, want %q", c.err, got, c.want)
		}
	}
}

// TestSendProviderCancelMetersDeliveryFailure: a cancel that cannot be handed
// to the provider writer is no longer Debug-only — it is counted on
// inference.cancel_send_failed with a bounded reason. A provider whose writer
// is gone (disconnect race, the historical "expected case") reports
// writer_stopped through the real DogStatsD client.
func TestSendProviderCancelMetersDeliveryFailure(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	srv := newComposedServer(registry.New(logger), memory.NewMemory(store.Config{AdminKey: "k"}), TestServerConfig{}, logger)
	controller := srv.cancels
	dd := newTestDD(t, collector)
	defer dd.Close()
	controller.Observation.SetDatadog(dd)

	// Connected as far as the Server can tell (Conn set) but its writer has
	// been torn down: EnqueueText fails with the writer-stopped sentinel.
	p := &registry.Provider{ID: "p-dead", Conn: &websocket.Conn{}}
	if controller.SendProviderCancel(p, "req-1") {
		t.Fatal("sendProviderCancel must report failure when the writer is gone")
	}
	_ = dd.Statsd.Flush()
	packets := collector.drain()
	got := findMetrics(packets, cancellation.MetricCancelSendFailed)
	if len(got) != 1 || !strings.Contains(got[0], "reason:writer_stopped") {
		t.Fatalf("cancel_send_failed packets = %v, want one with reason:writer_stopped", got)
	}
	for _, pk := range got {
		if strings.Contains(pk, "req-1") || strings.Contains(pk, "p-dead") {
			t.Fatalf("metric must not carry request or provider identity: %q", pk)
		}
	}

	// No socket at all is a test fixture, not a delivery failure: no metric.
	if controller.SendProviderCancel(&registry.Provider{ID: "p-nosock"}, "req-2") {
		t.Fatal("provider without a socket cannot succeed")
	}
	_ = dd.Statsd.Flush()
	if extra := findMetrics(collector.drain(), cancellation.MetricCancelSendFailed); len(extra) != 0 {
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
	srv := newComposedServer(reg, memory.NewMemory(store.Config{AdminKey: "k"}), TestServerConfig{}, logger)
	controller := srv.cancels
	dd := newTestDD(t, collector)
	defer dd.Close()
	controller.Observation.SetDatadog(dd)
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
	controller.CancelDispatch(provider, finished, cancellation.CauseHedgeLoser)
	if provider.GetPending(finished.RequestID) != nil {
		t.Fatal("cancelDispatch must still remove the pending record")
	}
	if n := controller.Tracker.Len(); n != 0 {
		t.Fatalf("a racer that already completed must not be tracked as a zombie (size=%d)", n)
	}
	_ = dd.Statsd.Flush()
	if got := findMetrics(collector.drain(), cancellation.MetricCancelSent); len(got) != 0 {
		t.Fatalf("cancel_sent must not fire for a racer whose completion was ingressed: %v", got)
	}

	running := newPending("req-still-running")
	controller.CancelDispatch(provider, running, cancellation.CauseHedgeLoser)
	if n := controller.Tracker.Len(); n != 1 {
		t.Fatalf("a still-running racer must be tracked for terminal correlation (size=%d)", n)
	}
	_ = dd.Statsd.Flush()
	if got := findMetrics(collector.drain(), cancellation.MetricCancelSent); len(got) != 0 {
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
	index := &cancellation.Index{}
	controller := srv.cancels
	controller.Tracker = cancellation.NewTracker(index)
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	controller.Observation.SetDatadog(dd)
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
	entry := func(id string) cancellation.Entry {
		// This tracker is driven synchronously by this test; the live provider
		// exercises the real writer but never accesses the retained index.
		e := index.Lookup(id)

		if e == nil {
			t.Fatalf("no zombie entry for %s", id)
		}
		return *e
	}
	drain := func() []string {
		_ = dd.Statsd.Flush()
		return collector.drain()
	}

	// Enqueue fails: recorded, unsent, not counted.
	t0 := time.Now()
	controller.SendAbandonCancel(dead, "req-fail", model, cancellation.CauseClientGonePost)
	packets := drain()
	if got := findMetrics(packets, cancellation.MetricCancelSent); len(got) != 0 {
		t.Fatalf("a failed enqueue must not count as sent: %v", got)
	}
	requireMetricWithTags(t, packets, cancellation.MetricCancelSendFailed, "reason:writer_stopped")
	if e := entry("req-fail"); e.Sent != 0 || e.Cause != cancellation.CauseClientGonePost {
		t.Fatalf("entry after failed send = %+v, want sent=0 with the abandon cause", e)
	}

	// The provider finishes on its own: correlated, but no cancel was delivered.
	e, ok := controller.ResolveCancelledTerminal("req-fail", cancellation.TerminalComplete, cancellation.OutcomeCompletePartial, t0.Add(time.Second))
	if !ok || e.Sent != 0 {
		t.Fatalf("terminal correlation = (%+v, %v), want the unsent entry", e, ok)
	}
	packets = drain()
	if got := findMetrics(packets, cancellation.MetricCancelToTerminalMs); len(got) != 0 {
		t.Fatalf("no cancel reached the provider, so no cancel→terminal latency: %v", got)
	}
	requireMetricWithTags(t, packets, cancellation.MetricCancelledTerminal,
		"outcome:"+cancellation.OutcomeCompletePartial, "cause:"+cancellation.CauseClientGonePost, "delivered:false")

	// Enqueue fails, then a stray chunk retries on a writer that accepts: the
	// first DELIVERED cancel counts cancel_sent once under the abandon cause.
	controller.SendAbandonCancel(dead, "req-retry", model, cancellation.CauseFirstChunkTimeout)
	packets = drain()
	if got := findMetrics(packets, cancellation.MetricCancelSent); len(got) != 0 {
		t.Fatalf("a failed enqueue must not count as sent: %v", got)
	}
	controller.NoteStrayChunk(live, live.ID, "req-retry", time.Now().Add(cancellation.ResendRetry))
	packets = drain()
	requireMetricWithTags(t, packets, cancellation.MetricCancelSent, "cause:"+cancellation.CauseFirstChunkTimeout, "model:"+model)
	requireMetricWithTags(t, packets, cancellation.MetricZombieStreamCancel, "resend_index:0")
	if e := entry("req-retry"); e.Sent != 1 {
		t.Fatalf("entry after the delivered retry = %+v, want sent=1", e)
	}
	if _, ok := controller.ResolveCancelledTerminal("req-retry", cancellation.TerminalError, cancellation.OutcomeErrorCancelled, time.Now()); !ok {
		t.Fatal("delivered retry must still correlate its terminal")
	}
	packets = drain()
	requireMetricWithTags(t, packets, cancellation.MetricCancelToTerminalMs, "terminal:"+cancellation.TerminalError, "cause:"+cancellation.CauseFirstChunkTimeout)
	requireMetricWithTags(t, packets, cancellation.MetricCancelledTerminal,
		"outcome:"+cancellation.OutcomeErrorCancelled, "cause:"+cancellation.CauseFirstChunkTimeout, "delivered:true")
	// A stray chunk can win the initial enqueue while the abandon path is
	// releasing registry capacity. Its later send is a resend, not another
	// first cancel for this request.
	controller.Tracker.Record("req-stray-first", model, cancellation.CauseClientGonePre, time.Now())
	controller.NoteStrayChunk(live, live.ID, "req-stray-first", time.Now())
	controller.SendRecordedCancel(live, "req-stray-first", model, cancellation.CauseClientGonePre)
	packets = drain()
	if got := sumMetric(t, packets, cancellation.MetricCancelSent, "cause:"+cancellation.CauseClientGonePre, "model:"+model); got != 1 {
		t.Fatalf("a stray-first race must count one initial cancel, got %v: %v", got, packets)
	}

	// A live writer: counted on the first send, exactly once.
	controller.SendAbandonCancel(live, "req-live", model, cancellation.CauseHedgeLoser)
	packets = drain()
	if got := requireMetricWithTags(t, packets, cancellation.MetricCancelSent, "cause:"+cancellation.CauseHedgeLoser, "model:"+model); len(got) != 1 {
		t.Fatalf("cancel_sent for a delivered first send = %v, want exactly one", got)
	}
	if e := entry("req-live"); e.Sent != 1 {
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
	for name, controller := range map[string]*cancellation.Controller{
		"nil canceller":     {},
		"literal canceller": {Tracker: &cancellation.Tracker{}},
	} {
		t.Run(name, func(t *testing.T) {
			srv := inference.New(inference.Dependencies{Registry: reg, Logger: logger, Cancellation: controller}, inference.Config{})
			provider := &registry.Provider{ID: "p-bare"}
			const unknownID = "never-dispatched"
			srv.HandleChunk("p-bare", provider, &protocol.InferenceResponseChunkMessage{
				Type: protocol.TypeInferenceResponseChunk, RequestID: unknownID,
			})
			srv.HandleInferenceError("p-bare", provider, &protocol.InferenceErrorMessage{
				Type: protocol.TypeInferenceError, RequestID: unknownID,
				Error: "boom", StatusCode: 500,
				FailureCode: protocol.FailureCodeGenerationFailure,
			})
			srv.HandleCompleteAt("p-bare", provider, &protocol.InferenceCompleteMessage{
				Type: protocol.TypeInferenceComplete, RequestID: unknownID,
			}, time.Now())
			// A second chunk for the same id exercises the re-send path too.
			srv.HandleChunk("p-bare", provider, &protocol.InferenceResponseChunkMessage{
				Type: protocol.TypeInferenceResponseChunk, RequestID: unknownID,
			})
		})
	}
}

func TestCancelLatencyUsesFirstSuccessfulSend(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	controller := &cancellation.Controller{Observation: observation.New(observation.Dependencies{}), Tracker: cancellation.NewTracker(nil)}
	controller.Observation.SetDatadog(dd)
	t0 := time.Now()
	for _, terminal := range []string{cancellation.TerminalComplete, cancellation.TerminalStrayChunk} {
		id := "delayed-" + terminal
		controller.Tracker.Record(id, "m", cancellation.CauseClientGonePost, t0)
		controller.Tracker.NoteSendFailed(id, t0)
		controller.Tracker.MarkSent(id, t0.Add(10*time.Second))
		// A later resend must not move the latency anchor.
		controller.Tracker.MarkSent(id, t0.Add(11*time.Second))
		if terminal == cancellation.TerminalComplete {
			controller.ResolveCancelledTerminal(id, terminal, cancellation.OutcomeCompletePartial, t0.Add(12*time.Second))
		} else {
			controller.Tracker.StrayChunk(id, t0.Add(12*time.Second))
			e, _ := controller.Tracker.Terminal(id)
			controller.EmitExpiredCancelEntries([]cancellation.Entry{e})
		}
		_ = dd.Statsd.Flush()
		packets := collector.drain()
		got := requireMetricWithTags(t, packets, cancellation.MetricCancelToTerminalMs, "terminal:"+terminal)
		if len(got) != 1 || !strings.Contains(got[0], cancellation.MetricCancelToTerminalMs+":2000|h") {
			t.Fatalf("latency must exclude the failed-send delay: %v", got)
		}
	}
}

func TestExpiredUndeliveredCancelIsUnresolved(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	controller := &cancellation.Controller{Observation: observation.New(observation.Dependencies{}), Tracker: cancellation.NewTracker(nil)}
	controller.Observation.SetDatadog(dd)
	t0 := time.Now()
	// The failed retry sees a stray chunk, but still delivers no cancel.
	controller.Tracker.Record("unsent", "m", cancellation.CauseClientGonePre, t0)
	controller.Tracker.NoteSendFailed("unsent", t0)
	controller.Tracker.StrayChunk("unsent", t0.Add(time.Second))
	controller.Tracker.NoteSendFailed("unsent", t0.Add(time.Second))
	e, _ := controller.Tracker.Terminal("unsent")
	controller.EmitExpiredCancelEntries([]cancellation.Entry{e})
	_ = dd.Statsd.Flush()
	packets := collector.drain()
	if got := findMetrics(packets, cancellation.MetricCancelToTerminalMs); len(got) != 0 {
		t.Fatalf("undelivered cancel must not contribute latency: %v", got)
	}
	requireMetricWithTags(t, packets, cancellation.MetricCancelUnresolved, "cause:"+cancellation.CauseClientGonePre)
}
