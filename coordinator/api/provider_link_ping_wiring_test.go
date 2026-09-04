package api

import (
	"context"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

// TestLinkPingModeFromEnv pins the one switch: off unless observe/close.
func TestLinkPingModeFromEnv(t *testing.T) {
	for _, tc := range []struct {
		in              string
		enabled, closeA bool
	}{
		{"", false, false},
		{"on", false, false},
		{"off", false, false},
		{"observe", true, false},
		{" Observe ", true, false},
		{"close", true, true},
		{"CLOSE", true, true},
	} {
		enabled, closeA := linkPingModeFromEnv(tc.in)
		if enabled != tc.enabled || closeA != tc.closeA {
			t.Errorf("linkPingModeFromEnv(%q) = (%v, %v), want (%v, %v)", tc.in, enabled, closeA, tc.enabled, tc.closeA)
		}
	}
	srv, _ := testServer(t)
	if srv.linkPingEnabled || srv.linkPingClose {
		t.Fatalf("keepalive must default to off (enabled=%v close=%v)", srv.linkPingEnabled, srv.linkPingClose)
	}
}

// TestLinkPingDefaultOffNeverPingsRegisteredProvider: through the real
// /ws/provider handshake, a server with the default switch never pings the
// registered provider (no RTT sample), so a fleet on a provider release that
// cannot skip payload-bearing pings sees no control frames from the
// coordinator at all.
func TestLinkPingDefaultOffNeverPingsRegisteredProvider(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	h := newSessionReasonHarness(t, ctx)
	go func() {
		for {
			if _, _, err := h.conn.Read(ctx); err != nil {
				return
			}
		}
	}()
	time.Sleep(400 * time.Millisecond)
	ids := h.reg.ProviderIDs()
	if len(ids) != 1 {
		t.Fatalf("providers = %d, want 1", len(ids))
	}
	p := h.reg.GetProvider(ids[0])
	if rtt := p.LinkRTT(); rtt.Samples != 0 {
		t.Fatalf("default-off keepalive recorded RTT samples: %+v", rtt)
	}
}

// TestLinkPingWiringRecordsRTTThroughProviderHandshake: with the loop in
// observe mode the /ws/provider handler starts it for the registered
// connection (provider.go: saferun.Go linkPing) and RTT samples land on the
// registry's provider — the default-ON half of the keepalive, previously
// asserted only by tests that called linkPingLoop directly.
func TestLinkPingWiringRecordsRTTThroughProviderHandshake(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	h := newSessionReasonHarnessConfigure(t, ctx, nil, nil, func(s *Server) {
		s.SetLinkPingForTesting(50*time.Millisecond, 2*time.Second)
	})
	// The provider reads, so nhooyr answers the coordinator's pings.
	go func() {
		for {
			if _, _, err := h.conn.Read(ctx); err != nil {
				return
			}
		}
	}()
	ids := h.reg.ProviderIDs()
	if len(ids) != 1 {
		t.Fatalf("providers = %d, want 1", len(ids))
	}
	p := h.reg.GetProvider(ids[0])
	waitFor(t, 5*time.Second, "RTT samples on the registered provider", func() bool {
		return p.LinkRTT().Samples >= 2
	})
	if rtt := p.LinkRTT(); rtt.EWMAMs <= 0 || rtt.LastMs <= 0 {
		t.Fatalf("RTT samples without a positive value: %+v", rtt)
	}
	if p.LinkPingTimedOut() {
		t.Fatal("healthy provider was marked ping-timed-out")
	}
}

// TestLinkPingWiringPingTimeoutSessionReason: with the close action on and a
// provider whose reader has stopped (it never pongs), the keepalive closes
// the socket and the read loop labels the disconnect ping_timeout on the
// session row — the pingTimedOut branch of providerReadLoop, executed end to
// end.
func TestLinkPingWiringPingTimeoutSessionReason(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	h := newSessionReasonHarnessConfigure(t, ctx, nil, nil, func(s *Server) {
		s.SetLinkPingForTesting(100*time.Millisecond, 500*time.Millisecond)
		s.SetLinkPingCloseForTesting(true)
	})
	// The harness never reads on h.conn: the provider's reader has stopped,
	// so no pong is ever produced.
	if reason := h.closedReason(t); reason != "ping_timeout" {
		t.Fatalf("disconnect_reason = %q, want ping_timeout", reason)
	}
	waitFor(t, 5*time.Second, "provider removed from the registry", func() bool {
		return h.reg.ProviderCount() == 0
	})
	_ = h.conn.Close(websocket.StatusNormalClosure, "")
}
