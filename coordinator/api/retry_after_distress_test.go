package api

// estimateRetryAfter distress-scaling tests (2026-09-01 congestion collapse).
//
// Queue depth alone was a liar under CPU saturation: the queue was empty
// (nothing could reach it), so every 429 carried "Retry-After: 2" and
// upstream retried every 2s, sustaining the death loop. When the attempt-0
// route-latency EWMA shows routing itself is degraded (> 1s), the answer
// must scale with the observed degradation — max(base, ceil(EWMA_s)*5),
// capped at 60 — while healthy routing keeps the legacy queue-depth values.

import (
	"testing"
	"time"
)

func TestEstimateRetryAfter_DistressScaling(t *testing.T) {
	t.Run("healthy keeps legacy empty-queue answer", func(t *testing.T) {
		srv, _ := testServer(t)
		if got := srv.estimateRetryAfter("m"); got != 2 {
			t.Fatalf("healthy empty-queue Retry-After = %d, want legacy 2", got)
		}
		// Sub-threshold degradation (EWMA <= 1s) changes nothing.
		srv.noteAttempt0RouteLatency(800 * time.Millisecond)
		if got := srv.estimateRetryAfter("m"); got != 2 {
			t.Fatalf("sub-threshold EWMA Retry-After = %d, want legacy 2", got)
		}
	})

	t.Run("degraded EWMA scales at least 5x", func(t *testing.T) {
		srv, _ := testServer(t)
		// The incident shape: attempt-0 route p50 at 4.6s.
		srv.noteAttempt0RouteLatency(4600 * time.Millisecond)
		got := srv.estimateRetryAfter("m")
		if want := 25; got != want { // ceil(4.6)*5
			t.Fatalf("degraded Retry-After = %d, want %d (ceil(4.6s)*5)", got, want)
		}
		if got < 5*2 {
			t.Fatalf("degraded Retry-After = %d, want >= 5x the healthy answer", got)
		}
	})

	t.Run("distress answer caps at 60", func(t *testing.T) {
		srv, _ := testServer(t)
		srv.noteAttempt0RouteLatency(90 * time.Second)
		if got := srv.estimateRetryAfter("m"); got != maxDistressRetryAfter {
			t.Fatalf("capped Retry-After = %d, want %d", got, maxDistressRetryAfter)
		}
	})

	t.Run("healthy samples pull a degraded EWMA back to legacy", func(t *testing.T) {
		srv, _ := testServer(t)
		srv.noteAttempt0RouteLatency(4600 * time.Millisecond)
		for i := 0; i < 15; i++ { // 4600 * 0.8^15 ≈ 162ms
			srv.noteAttempt0RouteLatency(40 * time.Millisecond)
		}
		if got := srv.estimateRetryAfter("m"); got != 2 {
			t.Fatalf("recovered Retry-After = %d, want legacy 2 (EWMA=%.0fms)",
				got, srv.attempt0RouteEWMAMs())
		}
	})

	t.Run("negative samples are dropped", func(t *testing.T) {
		srv, _ := testServer(t)
		srv.noteAttempt0RouteLatency(-5 * time.Second)
		if got := srv.attempt0RouteEWMAMs(); got != 0 {
			t.Fatalf("EWMA after negative sample = %v, want 0", got)
		}
	})
}
