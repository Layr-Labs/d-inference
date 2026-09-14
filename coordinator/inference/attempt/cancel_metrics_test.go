package attempt

import (
	"strings"
	"testing"
	"time"
)

func TestCancelLatencyUsesFirstSuccessfulSend(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv := New(Dependencies{Metrics: dd, Tracker: NewTracker()})
	t0 := time.Now()
	for _, terminal := range []string{CancelTerminalComplete, CancelTerminalStrayChunk} {
		id := "delayed-" + terminal
		srv.deps.Tracker.record(id, "m", CancelCauseClientGonePost, t0)
		srv.deps.Tracker.noteSendFailed(id, t0)
		srv.deps.Tracker.markSent(id, t0.Add(10*time.Second))
		// A later resend must not move the latency anchor.
		srv.deps.Tracker.markSent(id, t0.Add(11*time.Second))
		if terminal == CancelTerminalComplete {
			srv.ResolveCancelledTerminal(id, terminal, CancelledOutcomeCompletePartial, t0.Add(12*time.Second))
		} else {
			srv.deps.Tracker.strayChunk(id, t0.Add(12*time.Second))
			e, _ := srv.deps.Tracker.terminal(id)
			srv.emitExpiredCancelEntries([]Cancellation{e})
		}
		_ = dd.Statsd.Flush()
		packets := collector.drain()
		got := requireMetricWithTags(t, packets, MetricCancelToTerminalMs, "terminal:"+terminal)
		if len(got) != 1 || !strings.Contains(got[0], MetricCancelToTerminalMs+":2000|h") {
			t.Fatalf("latency must exclude the failed-send delay: %v", got)
		}
	}
}

func TestExpiredUndeliveredCancelIsUnresolved(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv := New(Dependencies{Metrics: dd, Tracker: NewTracker()})
	t0 := time.Now()
	// The failed retry sees a stray chunk, but still delivers no cancel.
	srv.deps.Tracker.record("unsent", "m", CancelCauseClientGonePre, t0)
	srv.deps.Tracker.noteSendFailed("unsent", t0)
	srv.deps.Tracker.strayChunk("unsent", t0.Add(time.Second))
	srv.deps.Tracker.noteSendFailed("unsent", t0.Add(time.Second))
	e, _ := srv.deps.Tracker.terminal("unsent")
	srv.emitExpiredCancelEntries([]Cancellation{e})
	_ = dd.Statsd.Flush()
	packets := collector.drain()
	if got := findMetrics(packets, MetricCancelToTerminalMs); len(got) != 0 {
		t.Fatalf("undelivered cancel must not contribute latency: %v", got)
	}
	requireMetricWithTags(t, packets, MetricCancelUnresolved, "cause:"+CancelCauseClientGonePre)
}
