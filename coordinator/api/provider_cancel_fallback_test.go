package api

import (
	"bytes"
	"context"
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
	if !srv.sendProviderCancel(provider, "req-cancel-1") {
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

	if !srv.sendProviderCancel(provider, "req-fast-1") {
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
		if !srv.sendProviderCancel(provider, "zombie-"+strconv.Itoa(i)) {
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
	if srv.sendProviderCancel(provider, strings.Repeat("z", 300)) {
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
