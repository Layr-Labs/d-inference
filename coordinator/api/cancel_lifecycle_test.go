package api

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
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
		if got := cancelSendFailureReason(c.err); got != c.want {
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
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{AdminKey: "k"}), ServerConfig{}, logger)
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)

	// Connected as far as the Server can tell (Conn set) but its writer has
	// been torn down: EnqueueText fails with the writer-stopped sentinel.
	p := &registry.Provider{ID: "p-dead", Conn: &websocket.Conn{}}
	if srv.sendProviderCancel(p, "req-1") {
		t.Fatal("sendProviderCancel must report failure when the writer is gone")
	}
	_ = dd.Statsd.Flush()
	packets := collector.drain()
	got := findMetrics(packets, metricCancelSendFailed)
	if len(got) != 1 || !strings.Contains(got[0], "reason:writer_stopped") {
		t.Fatalf("cancel_send_failed packets = %v, want one with reason:writer_stopped", got)
	}
	for _, pk := range got {
		if strings.Contains(pk, "req-1") || strings.Contains(pk, "p-dead") {
			t.Fatalf("metric must not carry request or provider identity: %q", pk)
		}
	}

	// No socket at all is a test fixture, not a delivery failure: no metric.
	if srv.sendProviderCancel(&registry.Provider{ID: "p-nosock"}, "req-2") {
		t.Fatal("provider without a socket cannot succeed")
	}
	_ = dd.Statsd.Flush()
	if extra := findMetrics(collector.drain(), metricCancelSendFailed); len(extra) != 0 {
		t.Fatalf("nil Conn must not be metered as a delivery failure: %v", extra)
	}
}

// TestCancelDispatchSkipsCancelAfterCompletionIngress pins the hedge-loser
// edge case: a racer that completed EMPTY on time is parked by handleComplete
// on the speculative empty-completion decision WITHOUT RemovePending, so its
// record is still live when cancelDispatch runs — yet the completion ingress
// proves nothing is running. No cancel, no cancel_sent, no zombie entry. A
// racer with no terminal at all still gets its cancel recorded and counted.
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
	srv.cancelDispatch(provider, finished, cancelCauseHedgeLoser)
	if provider.GetPending(finished.RequestID) != nil {
		t.Fatal("cancelDispatch must still remove the pending record")
	}
	if n := srv.zombieCanceller.size(); n != 0 {
		t.Fatalf("a racer that already completed must not be tracked as a zombie (size=%d)", n)
	}
	_ = dd.Statsd.Flush()
	if got := findMetrics(collector.drain(), metricCancelSent); len(got) != 0 {
		t.Fatalf("cancel_sent must not fire for a racer whose completion was ingressed: %v", got)
	}

	running := newPending("req-still-running")
	srv.cancelDispatch(provider, running, cancelCauseHedgeLoser)
	if n := srv.zombieCanceller.size(); n != 1 {
		t.Fatalf("a still-running racer must be tracked for terminal correlation (size=%d)", n)
	}
	_ = dd.Statsd.Flush()
	requireMetricWithTags(t, collector.drain(), metricCancelSent, "cause:"+cancelCauseHedgeLoser, "model:"+model)
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
		"literal canceller": {registry: reg, logger: logger, zombieCanceller: &zombieStreamCanceller{}},
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
