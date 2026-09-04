package api

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

// TestLinkPingLoopRecordsRTT: with a peer that reads (and therefore answers
// pings, as every WebSocket implementation must), the loop records RTT
// samples and never marks the connection timed out.
func TestLinkPingLoopRecordsRTT(t *testing.T) {
	serverConn, clientConn := testWebSocketPairAPI(t)
	// Peer read loop: nhooyr answers pings from inside Read.
	go func() {
		for {
			if _, _, err := clientConn.Read(context.Background()); err != nil {
				return
			}
		}
	}()
	// Coordinator read loop: pong frames are consumed inside Read too.
	go func() {
		for {
			if _, _, err := serverConn.Read(context.Background()); err != nil {
				return
			}
		}
	}()

	srv, _ := testServer(t)
	srv.SetLinkPingForTesting(50*time.Millisecond, 2*time.Second)
	reg := registry.New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	provider := reg.Register("ping-rtt-provider", serverConn, &protocol.RegisterMessage{})
	defer reg.Disconnect(provider.ID)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() {
		defer close(done)
		srv.linkPingLoop(ctx, provider.ID, provider, serverConn)
	}()

	deadline := time.Now().Add(5 * time.Second)
	for {
		rtt := provider.LinkRTT()
		if rtt.Samples >= 3 {
			if rtt.EWMAMs <= 0 || rtt.LastMs <= 0 {
				t.Fatalf("RTT samples recorded without a positive value: %+v", rtt)
			}
			if rtt.EWMAMs > 1000 {
				t.Fatalf("loopback RTT implausibly high: %+v", rtt)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("expected ≥3 RTT samples, got %+v", rtt)
		}
		time.Sleep(10 * time.Millisecond)
	}
	if provider.LinkPingTimedOut() {
		t.Fatal("healthy peer was marked ping-timed-out")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("ping loop did not stop on ctx cancel")
	}
}

// TestLinkPingLoopClosesSilentPeer: a peer that never reads never answers
// pings. After the configured consecutive failures the loop marks the
// provider and closes the socket so the read loop tears the session down
// with reason ping_timeout — instead of waiting ~2 minutes for eviction.
func TestLinkPingLoopClosesSilentPeer(t *testing.T) {
	serverConn, _ := testWebSocketPairAPI(t) // client never reads => never pongs
	readErr := make(chan error, 1)
	go func() {
		_, _, err := serverConn.Read(context.Background())
		readErr <- err
	}()

	srv, _ := testServer(t)
	srv.SetLinkPingForTesting(50*time.Millisecond, 150*time.Millisecond)
	srv.SetLinkPingCloseForTesting(true)
	reg := registry.New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	provider := reg.Register("ping-silent-provider", serverConn, &protocol.RegisterMessage{})
	defer reg.Disconnect(provider.ID)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() {
		defer close(done)
		srv.linkPingLoop(ctx, provider.ID, provider, serverConn)
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("ping loop did not give up on a silent peer")
	}
	if !provider.LinkPingTimedOut() {
		t.Fatal("silent peer was not marked ping-timed-out")
	}
	var loopErr error
	select {
	case loopErr = <-readErr:
		if loopErr == nil {
			t.Fatal("read loop returned nil after ping-timeout close")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("read loop was not unblocked by the ping-timeout close")
	}
	// The read loop maps this exact combination to the session reason.
	if got := sessionDisconnectReason(websocket.CloseStatus(loopErr), false, readErrorReasonGeneric, provider.LinkPingTimedOut()); got != "ping_timeout" {
		t.Fatalf("disconnect reason = %q, want ping_timeout", got)
	}
}

// TestLinkPingLoopDisabled: the testing switch keeps the loop from touching
// the socket at all.
func TestLinkPingLoopDisabled(t *testing.T) {
	serverConn, _ := testWebSocketPairAPI(t)
	srv, _ := testServer(t)
	srv.SetDisableLinkPing(true)
	reg := registry.New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	provider := reg.Register("ping-disabled-provider", serverConn, &protocol.RegisterMessage{})
	defer reg.Disconnect(provider.ID)
	done := make(chan struct{})
	go func() {
		defer close(done)
		srv.linkPingLoop(context.Background(), provider.ID, provider, serverConn)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("disabled ping loop should return immediately")
	}
	if provider.LinkRTT().Samples != 0 {
		t.Fatal("disabled loop recorded RTT")
	}
}

// TestLinkPingLoopSkipsWhileDataWriteInFlight: with a multi-MiB frame stalled
// in the socket write (peer not draining), the loop must not probe — and so
// must not let the library's 5s control budget kill the connection — nor
// count the skipped ticks as failures.
func TestLinkPingLoopSkipsWhileDataWriteInFlight(t *testing.T) {
	serverConn, _ := testWebSocketPairAPI(t) // client never reads
	srv, _ := testServer(t)
	srv.SetLinkPingForTesting(50*time.Millisecond, 100*time.Millisecond)
	reg := registry.New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	provider := reg.Register("ping-inflight-provider", serverConn, &protocol.RegisterMessage{})
	defer reg.Disconnect(provider.ID)

	payload := bytes.Repeat([]byte("x"), 32<<20)
	go func() { _ = provider.WriteText(context.Background(), payload) }()
	deadline := time.Now().Add(3 * time.Second)
	for !provider.WriteInFlight() {
		if time.Now().After(deadline) {
			t.Fatal("stalled write never became in-flight")
		}
		time.Sleep(5 * time.Millisecond)
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		srv.linkPingLoop(ctx, provider.ID, provider, serverConn)
	}()
	// Several would-be probe intervals pass while the write is stalled.
	time.Sleep(600 * time.Millisecond)
	if provider.LinkPingTimedOut() {
		t.Fatal("ping loop declared a timeout while a data write was in flight")
	}
	select {
	case <-done:
		t.Fatal("ping loop exited while the write was in flight")
	default:
	}
	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("ping loop did not stop on ctx cancel")
	}
}

// TestLinkPingLoopSkipsWhileReadLoopBusy: a pong the coordinator could not
// read because its own read goroutine was inside a handler must not count
// against the provider.
func TestLinkPingLoopSkipsWhileReadLoopBusy(t *testing.T) {
	serverConn, _ := testWebSocketPairAPI(t) // client never reads => no pongs
	srv, _ := testServer(t)
	srv.SetLinkPingForTesting(50*time.Millisecond, 100*time.Millisecond)
	srv.SetLinkPingCloseForTesting(true)
	reg := registry.New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	provider := reg.Register("ping-busy-provider", serverConn, &protocol.RegisterMessage{})
	defer reg.Disconnect(provider.ID)
	provider.SetReadLoopBusy(true)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		srv.linkPingLoop(ctx, provider.ID, provider, serverConn)
	}()
	time.Sleep(700 * time.Millisecond)
	if provider.LinkPingTimedOut() {
		t.Fatal("ping loop blamed the provider for a busy coordinator read loop")
	}
	select {
	case <-done:
		t.Fatal("ping loop exited while the read loop was busy")
	default:
	}
	// Once the read loop is back in Read, silence is the peer's fault again.
	provider.SetReadLoopBusy(false)
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("ping loop did not give up on the silent peer after the reader freed up")
	}
	if !provider.LinkPingTimedOut() {
		t.Fatal("silent peer was not marked ping-timed-out")
	}
	cancel()
}

// TestLinkPingLoopCloseOffKeepsSilentPeer: with the close action off (the
// production default until the false-miss rate is known), a silent peer is
// still probed and every miss is counted — including the would-close point —
// but the socket is never closed and the provider is never marked timed out;
// the provider's own pong timeout and the staleness sweep remain the only
// reapers.
func TestLinkPingLoopCloseOffKeepsSilentPeer(t *testing.T) {
	serverConn, _ := testWebSocketPairAPI(t) // client never reads => never pongs
	readErr := make(chan error, 1)
	go func() {
		_, _, err := serverConn.Read(context.Background())
		readErr <- err
	}()

	srv, _ := testServer(t)
	collector, dd := attachTestDD(t, srv)
	srv.SetLinkPingForTesting(50*time.Millisecond, 100*time.Millisecond)
	if srv.linkPingClose {
		t.Fatal("close action must default to off")
	}
	reg := registry.New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	provider := reg.Register("ping-observe-provider", serverConn, &protocol.RegisterMessage{})
	defer reg.Disconnect(provider.ID)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		srv.linkPingLoop(ctx, provider.ID, provider, serverConn)
	}()
	// Several would-close points pass.
	time.Sleep(900 * time.Millisecond)
	select {
	case err := <-readErr:
		t.Fatalf("socket was closed (%v) although the close action is off", err)
	case <-done:
		t.Fatal("ping loop exited although the close action is off")
	default:
	}
	if provider.LinkPingTimedOut() {
		t.Fatal("observe-only loop marked the provider timed out")
	}
	packets := dd.packets(collector)
	if !hasMetric(packets, "provider.ws.ping_failed") {
		t.Fatalf("missing provider.ws.ping_failed; packets: %v", packets)
	}
	if !hasMetric(packets, "provider.ws.ping_would_close") {
		t.Fatalf("missing provider.ws.ping_would_close; packets: %v", packets)
	}
	if hasMetric(packets, "provider.ws.ping_timeout_close") {
		t.Fatalf("observe-only loop emitted a close: %v", packets)
	}
	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("ping loop did not stop on ctx cancel")
	}
}
