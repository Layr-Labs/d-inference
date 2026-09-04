package api

import (
	"context"
	"errors"
	"net"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

// Coordinator-side WebSocket keepalive + RTT probe.
//
// Until this loop existed the coordinator never wrote a ping and never set a
// read deadline: a provider whose socket died silently (sleeping laptop, NAT
// teardown, mid-write RST) stayed routable until the 90 s heartbeat-staleness
// sweep reaped it two sweeps later — 120–150 s in practice — and no RTT figure
// existed anywhere in the system. (A live provider whose link merely dropped
// is gone sooner today: its own 10 s pings time out at 30 s, it reconnects,
// and the duplicate-serial kick evicts the dead session; this loop improves
// the provider-DEAD class.) The provider already answers pings automatically
// (NWProtocolWebSocket autoReplyPing, and RFC 6455 requires it of every
// implementation), so a server-side ping costs one control frame each way
// and yields both a liveness signal and a round-trip sample.
//
// RTT is recorded per provider (EWMA) and published as a fleet histogram. It
// is observability only: routing does not read it.
//
// The CLOSE action is behind EIGENINFERENCE_LINK_PING_CLOSE and defaults to
// OFF: pongs are consumed on the coordinator's read goroutine, so under a
// coordinator-side CPU collapse (the #799 regime) a 15 s / 10 s / 2-miss
// policy could reap healthy providers faster than evictStale's two-strike
// protection — a false close takes the abrupt disconnect path (502 flush
// plus strikes). Observe-only first: ping, sample RTT, count ping_failed and
// ping_would_close; enable the close once those series show the false-miss
// rate under load.
const (
	// linkPingInterval is the steady-state ping cadence per connection. Fleet
	// cost at ~1,300 providers is ~90 control frames/s each way.
	linkPingInterval = 15 * time.Second
	// linkPingTimeout bounds one ping→pong wait. It must exceed any expected
	// read-loop stall on the provider read goroutine (register-time DB reads,
	// attestation verification) so a busy-but-alive link is never misread.
	linkPingTimeout = 10 * time.Second
	// linkPingInitialDelay lets registration (attestation, the first
	// challenge) settle before the first probe.
	linkPingInitialDelay = 2 * time.Second
	// linkPingFailuresToClose is the number of consecutive unanswered pings
	// before the connection is declared dead. Two failures ≈ 2×(timeout +
	// interval) worst case, ~30–50s after the socket actually died.
	linkPingFailuresToClose = 2
	// linkPingRetryWhileWriting is how soon to re-check when a probe was
	// skipped because a data-lane write was in flight or the read loop was
	// inside a handler.
	linkPingRetryWhileWriting = 1 * time.Second
)

// SetLinkPingForTesting overrides the ping cadence and timeout (zero keeps
// the default). Test-only.
func (s *Server) SetLinkPingForTesting(interval, timeout time.Duration) {
	s.linkPingInterval = interval
	s.linkPingTimeout = timeout
}

// SetDisableLinkPing turns the server-side keepalive off (testing only).
func (s *Server) SetDisableLinkPing(disable bool) {
	s.disableLinkPing = disable
}

// SetLinkPingCloseForTesting sets the close action (the
// EIGENINFERENCE_LINK_PING_CLOSE switch) for tests.
func (s *Server) SetLinkPingCloseForTesting(enabled bool) {
	s.linkPingClose = enabled
}

// linkPingLoop pings one provider connection until ctx is cancelled or, with
// the close action enabled, the peer stops answering: on the
// linkPingFailuresToClose-th consecutive failure it marks the provider (so the
// read loop labels the disconnect "ping_timeout") and closes the socket, which
// unblocks the read loop and triggers normal teardown. With the close action
// off (the default) the same point emits provider.ws.ping_would_close, resets
// the streak, and keeps probing.
func (s *Server) linkPingLoop(ctx context.Context, providerID string, provider *registry.Provider, conn *websocket.Conn) {
	if s.disableLinkPing || conn == nil || provider == nil {
		return
	}
	interval := s.linkPingInterval
	if interval <= 0 {
		interval = linkPingInterval
	}
	timeout := s.linkPingTimeout
	if timeout <= 0 {
		timeout = linkPingTimeout
	}
	initial := linkPingInitialDelay
	if initial > interval {
		initial = interval
	}

	timer := time.NewTimer(initial)
	defer timer.Stop()
	failures := 0
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		// Never probe while a data-lane write is in flight. nhooyr writes
		// control frames under the same frame mutex with a fixed 5 s budget
		// and closes the connection when that budget expires; with the 64 KiB
		// fragmented writer a ping waits at most one fragment, but a send
		// buffer saturated by a multi-MiB dispatch to a slow provider could
		// still make the library kill a healthy link on the very first probe.
		// The pong the provider owes us is subject to the same budget, so a
		// saturated buffer also cannot be blamed on the peer.
		if provider.WriteInFlight() {
			timer.Reset(linkPingRetryWhileWriting)
			continue
		}
		pingCtx, cancel := context.WithTimeout(ctx, timeout)
		start := time.Now()
		err := conn.Ping(pingCtx)
		cancel()
		if ctx.Err() != nil {
			return
		}
		switch {
		case err == nil:
			rtt := time.Since(start)
			provider.RecordLinkRTT(rtt)
			s.ddHistogram("provider.ws.rtt_ms", float64(rtt)/float64(time.Millisecond), nil)
			failures = 0
		case errors.Is(err, net.ErrClosed):
			// Someone else already tore the socket down (the read loop saw a
			// peer close or reset, the write watchdog fired, ...). Not our
			// verdict: leave the read loop to classify it (read_error, OOM,
			// close code) and stand down.
			return
		case provider.ReadLoopBusy():
			// The pong may well have arrived — nhooyr only consumes pongs
			// inside Read, and the read goroutine was in a handler (heartbeat
			// drains, model-swap sends that can block on OTHER providers'
			// writers) for the whole window. That is a coordinator stall,
			// not a dead peer; do not count it against the provider.
			s.ddIncr("provider.ws.ping_skipped_busy_reader", nil)
			timer.Reset(linkPingRetryWhileWriting)
			continue
		default:
			failures++
			s.ddIncr("provider.ws.ping_failed", nil)
			if failures >= linkPingFailuresToClose {
				if !s.linkPingClose {
					// Observe-only: the verdict is recorded, the socket is
					// left to the provider's own pong timeout and the
					// staleness sweep.
					s.ddIncr("provider.ws.ping_would_close", nil)
					s.logger.Warn("provider stopped answering pings (close disabled)",
						"provider_id", providerID, "failures", failures, "timeout", timeout)
					failures = 0
					break
				}
				provider.MarkLinkPingTimeout()
				s.ddIncr("provider.ws.ping_timeout_close", nil)
				s.logger.Warn("closing provider connection after unanswered pings",
					"provider_id", providerID, "failures", failures, "timeout", timeout)
				_ = conn.CloseNow()
				return
			}
		}
		timer.Reset(interval)
	}
}
