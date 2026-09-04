package api

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// TestSendProviderCancelFallsBackWhenControlLaneFull reproduces the dropped
// cancel: the writer is stuck behind a large data frame to a provider that is
// not reading yet, the control lane fills up, and a cancel arrives. The old
// code dropped it at debug level; now it must still reach the provider once
// the lane drains, and the fallback must be metered.
func TestSendProviderCancelFallsBackWhenControlLaneFull(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	serverConn, clientConn := testWebSocketPairAPI(t)

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	srv, _ := testServer(t)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)

	provider := reg.Register("cancel-fallback-provider", serverConn, &protocol.RegisterMessage{})
	defer reg.Disconnect(provider.ID)

	// Stall the writer on a data frame far larger than the loopback socket
	// buffers; the client does not read until we let it.
	big := bytes.Repeat([]byte("x"), 8<<20)
	writeDone := make(chan error, 1)
	go func() { writeDone <- provider.WriteText(context.Background(), big) }()
	time.Sleep(200 * time.Millisecond)

	// Fill the control lane.
	filled := 0
	for i := 0; i < 1000; i++ {
		err := provider.EnqueueText(context.Background(), []byte(`{"type":"trust_status","filler":true}`))
		if err == registry.ErrProviderWriterQueueFull {
			break
		}
		if err != nil {
			t.Fatalf("unexpected enqueue error: %v", err)
		}
		filled++
	}
	if filled == 0 {
		t.Fatal("control lane never filled")
	}

	// The cancel must not be dropped even though the lane is full, and the
	// caller must learn it was handed off (wave-2 contract: true = the frame
	// reached the writer or the bounded fallback).
	if !srv.sendProviderCancel(provider, "req-cancel-1", nil) {
		t.Fatal("sendProviderCancel on a full control lane must report the fallback hand-off, not a drop")
	}

	// Now let the provider read everything; the cancel should be among the
	// control frames that follow the stalled data frame.
	sawCancel := make(chan struct{}, 1)
	go func() {
		for {
			_, data, err := clientConn.Read(context.Background())
			if err != nil {
				return
			}
			if string(data) == `{"type":"cancel","request_id":"req-cancel-1"}` {
				sawCancel <- struct{}{}
				return
			}
		}
	}()

	select {
	case err := <-writeDone:
		if err != nil {
			t.Fatalf("stalled data write failed: %v", err)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("data write never completed")
	}
	select {
	case <-sawCancel:
	case <-time.After(10 * time.Second):
		t.Fatal("cancel was dropped: provider never received it")
	}

	deadline := time.Now().Add(2 * time.Second)
	for provider.LinkStats().ControlFallbacks != 1 {
		if time.Now().After(deadline) {
			t.Fatalf("ControlFallbacks = %d, want 1", provider.LinkStats().ControlFallbacks)
		}
		time.Sleep(10 * time.Millisecond)
	}
	_ = ddClient.Statsd.Flush()
	packets := collector.drain()
	if !hasMetricWithTag(packets, metricCancelSendFailed, "reason:queue_full") {
		t.Errorf("missing %s{reason:queue_full}; packets: %v", metricCancelSendFailed, packets)
	}
	if hasMetric(packets, "provider.cancel_dropped") {
		t.Errorf("cancel should not have been dropped; packets: %v", packets)
	}
}

// TestSendProviderCancelFastPathUnchanged: with a free control lane the cancel
// is delivered without the fallback and without the fallback metric.
func TestSendProviderCancelFastPathUnchanged(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	serverConn, clientConn := testWebSocketPairAPI(t)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	srv, _ := testServer(t)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)

	provider := reg.Register("cancel-fast-provider", serverConn, &protocol.RegisterMessage{})
	defer reg.Disconnect(provider.ID)

	if !srv.sendProviderCancel(provider, "req-fast-1", nil) {
		t.Fatal("fast path must report the cancel as handed off")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, data, err := clientConn.Read(ctx)
	if err != nil {
		t.Fatalf("client read: %v", err)
	}
	if string(data) != `{"type":"cancel","request_id":"req-fast-1"}` {
		t.Fatalf("frame = %s", data)
	}
	if provider.LinkStats().ControlFallbacks != 0 {
		t.Fatal("fast path should not count a fallback")
	}
	_ = ddClient.Statsd.Flush()
	if packets := collector.drain(); hasMetric(packets, metricCancelSendFailed) {
		t.Errorf("fast path must not emit the send-failed metric: %v", packets)
	}
}

// TestSendProviderCancelBoundsFallbackGoroutines: once the control lane is
// full, only MaxControlFallbacksInFlight cancels may park in the blocking
// fallback per connection; the rest are dropped and counted, so a provider
// that stops draining while flooding unknown request IDs cannot grow the
// coordinator's goroutine count without bound.
func TestSendProviderCancelBoundsFallbackGoroutines(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	serverConn, _ := testWebSocketPairAPI(t) // client never reads: writer stalls
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	srv, _ := testServer(t)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)

	provider := reg.Register("cancel-bound-provider", serverConn, &protocol.RegisterMessage{})
	defer reg.Disconnect(provider.ID)

	big := bytes.Repeat([]byte("x"), 32<<20)
	go func() { _ = provider.WriteText(context.Background(), big) }()
	deadline := time.Now().Add(3 * time.Second)
	for !provider.WriteInFlight() {
		if time.Now().After(deadline) {
			t.Fatal("stalled write never became in-flight")
		}
		time.Sleep(5 * time.Millisecond)
	}
	for i := 0; i < 1000; i++ {
		if err := provider.EnqueueText(context.Background(), []byte(`{"filler":true}`)); err == registry.ErrProviderWriterQueueFull {
			break
		}
	}

	const flood = registry.MaxControlFallbacksInFlight * 4
	dropped := 0
	for i := 0; i < flood; i++ {
		if !srv.sendProviderCancel(provider, "zombie-"+strconv.Itoa(i), nil) {
			dropped++
		}
	}
	// The parked fallbacks hold their slots for the whole cancelWriteTimeout
	// (nothing drains the lane), so everything past the cap is dropped and
	// reported as such to the caller.
	if want := flood - registry.MaxControlFallbacksInFlight; dropped != want {
		t.Fatalf("sendProviderCancel reported %d drops, want %d (flood %d, cap %d)", dropped, want, flood, registry.MaxControlFallbacksInFlight)
	}
	// Oversized provider-controlled IDs never even reach the marshal.
	if srv.sendProviderCancel(provider, strings.Repeat("z", 300), nil) {
		t.Fatal("an oversized request id must be dropped, not sent")
	}

	_ = ddClient.Statsd.Flush()
	packets := collector.drain()
	capped := 0
	for _, p := range packets {
		if strings.Contains(p, "provider.cancel_dropped") && strings.Contains(p, "reason:fallback_cap") {
			capped++
		}
	}
	if capped == 0 {
		t.Fatalf("expected fallback-cap drops beyond %d in-flight; packets: %v", registry.MaxControlFallbacksInFlight, packets)
	}
	if !hasMetricWithTag(packets, "provider.cancel_dropped", "reason:oversized_id") {
		t.Fatalf("oversized request id was not dropped; packets: %v", packets)
	}
}

// parkedFullLaneProvider registers a provider whose writer is parked in a
// 32 MiB data write to a peer that never reads, with the control lane filled,
// so the next cancel takes the bounded fallback and stays parked there.
func parkedFullLaneProvider(t *testing.T, reg *registry.Registry, id string) *registry.Provider {
	t.Helper()
	serverConn, _ := testWebSocketPairAPI(t) // client never reads: writer stalls
	provider := reg.Register(id, serverConn, &protocol.RegisterMessage{})
	big := bytes.Repeat([]byte("x"), 32<<20)
	go func() { _ = provider.WriteText(context.Background(), big) }()
	deadline := time.Now().Add(3 * time.Second)
	for !provider.WriteInFlight() {
		if time.Now().After(deadline) {
			t.Fatal("stalled write never became in-flight")
		}
		time.Sleep(5 * time.Millisecond)
	}
	for i := 0; i < 1000; i++ {
		if err := provider.EnqueueText(context.Background(), []byte(`{"filler":true}`)); err == registry.ErrProviderWriterQueueFull {
			return provider
		}
	}
	t.Fatal("control lane never filled")
	return nil
}

// TestSendProviderCancelFallbackTeardownDropIsWriterStopped: a cancel parked
// in the control-lane fallback when the connection is torn down is a
// teardown drop — provider.cancel_dropped{reason:fallback_writer_stopped},
// never fallback_timeout (the control-lane capacity signal) — and the drop
// is reported to the caller so the zombie tracker learns the frame is lost.
func TestSendProviderCancelFallbackTeardownDropIsWriterStopped(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	srv, _ := testServer(t)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)

	provider := parkedFullLaneProvider(t, reg, "cancel-teardown-provider")
	dropped := make(chan error, 1)
	if !srv.sendProviderCancel(provider, "req-teardown", func(err error) { dropped <- err }) {
		t.Fatal("a full control lane must take the fallback, not report a drop")
	}
	select {
	case err := <-dropped:
		t.Fatalf("fallback reported a drop (%v) while still parked", err)
	case <-time.After(200 * time.Millisecond):
	}

	reg.Disconnect(provider.ID) // closes the writer under the parked fallback
	select {
	case err := <-dropped:
		if !errors.Is(err, registry.ErrProviderWriterStopped) {
			t.Fatalf("drop error = %v, want ErrProviderWriterStopped", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("fallback did not report the teardown drop")
	}
	_ = ddClient.Statsd.Flush()
	packets := collector.drain()
	if !hasMetricWithTag(packets, "provider.cancel_dropped", "reason:fallback_writer_stopped") {
		t.Fatalf("missing provider.cancel_dropped{reason:fallback_writer_stopped}; packets: %v", packets)
	}
	if hasMetricWithTag(packets, "provider.cancel_dropped", "reason:fallback_timeout") {
		t.Fatalf("teardown drop mislabelled as fallback_timeout; packets: %v", packets)
	}
}

// lookup is a test-only snapshot of one zombie entry.
func (z *zombieStreamCanceller) lookup(requestID string) (zombieEntry, bool) {
	z.mu.Lock()
	defer z.mu.Unlock()
	e, ok := z.entries[requestID]
	if !ok {
		return zombieEntry{}, false
	}
	return *e, true
}

// TestSendProviderCancelFallbackTimeoutDropNotesSendFailed: a fallback that
// runs out of cancelWriteTimeout on a live-but-wedged link is the capacity
// signal (fallback_timeout), and through sendRecordedCancel the drop is fed
// back to the zombie tracker as a failed send: the re-send is re-armed at
// drop + zombieResendRetry instead of the tracker believing the frame it
// stamped and counted was delivered.
func TestSendProviderCancelFallbackTimeoutDropNotesSendFailed(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	srv, _ := testServer(t)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)

	provider := parkedFullLaneProvider(t, reg, "cancel-timeout-provider")
	defer reg.Disconnect(provider.ID)

	pr := &registry.PendingRequest{RequestID: "req-fallback-timeout", Model: "m"}
	sentAt := time.Now()
	srv.sendAbandonCancel(provider, pr, cancelCauseClientGonePre)
	afterSend, ok := srv.zombieCanceller.lookup(pr.RequestID)
	if !ok {
		t.Fatal("abandon cancel was not recorded in the zombie tracker")
	}
	// markSent armed the first schedule point (+1 s from the first cancel).
	if d := afterSend.nextResendAt.Sub(afterSend.firstCancelAt); d != zombieResendSchedule[0] {
		t.Fatalf("markSent armed the re-send at +%v, want +%v", d, zombieResendSchedule[0])
	}

	// The fallback parks for cancelWriteTimeout, then drops and reports it.
	var afterDrop zombieEntry
	deadline := time.Now().Add(cancelWriteTimeout + 3*time.Second)
	for {
		e, ok := srv.zombieCanceller.lookup(pr.RequestID)
		if ok && !e.nextResendAt.Equal(afterSend.nextResendAt) {
			afterDrop = e
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("fallback timeout was not fed back to the zombie tracker (nextResendAt never re-armed)")
		}
		time.Sleep(20 * time.Millisecond)
	}
	observedAt := time.Now()
	if afterDrop.nextResendAt.Before(sentAt.Add(cancelWriteTimeout - 100*time.Millisecond)) {
		t.Fatalf("re-armed at +%v since send, before the %v fallback budget elapsed", afterDrop.nextResendAt.Sub(sentAt), cancelWriteTimeout)
	}
	if afterDrop.nextResendAt.After(observedAt.Add(zombieResendRetry)) {
		t.Fatalf("re-armed at %v after observation, want <= zombieResendRetry (%v)", afterDrop.nextResendAt.Sub(observedAt), zombieResendRetry)
	}
	_ = ddClient.Statsd.Flush()
	packets := collector.drain()
	if !hasMetricWithTag(packets, "provider.cancel_dropped", "reason:fallback_timeout") {
		t.Fatalf("missing provider.cancel_dropped{reason:fallback_timeout}; packets: %v", packets)
	}
	if hasMetricWithTag(packets, "provider.cancel_dropped", "reason:fallback_writer_stopped") {
		t.Fatalf("timeout drop mislabelled as fallback_writer_stopped; packets: %v", packets)
	}
}
