package api

// The request-absolute first-token clock.
//
// OpenRouter (and OpenRouter-shaped aggregators) cancel a request when no REAL
// completion token has arrived within ~10000ms + 1ms x prompt_tokens measured
// from the moment THEY sent the request. An HTTP 200, an SSE `: keepalive`
// comment, and a provider `inference_accepted` ack do not satisfy that rule.
// Production evidence (2026-08-15): ~11k/day client_gone rows fit that line
// within ±250ms while the coordinator was still waiting on a 600s post-accept
// budget.
//
// Everything here derives from one clock: ReceivedAt + ttftDeadline(tokens)
// (prod: 9s + 1ms/token — deliberately inside the aggregator's 10s slope).
// Invariants:
//
//  1. No wait for first CONTENT may extend past the leftover clock — not
//     accept, not preamble liveness, not a speculative race extension.
//  2. Expiry of OUR clock is not provider sickness. Per-provider fault
//     breakers may only be fed when the provider was actually granted a
//     provider-attributable window (providerAttributableStall).
//  3. The clock bounds blocking provider writes too (firstTokenWriteContext):
//     a congested write lane must not eat the budget invisibly.
//  4. A token that is already buffered beats the clock: deadline arms drain
//     ChunkCh before declaring a timeout (drainReadyFirstContent), because a
//     zero-duration timer and a ready chunk race in Go's select.
//  5. When ReceivedAt was never stamped (unit tests), every helper falls back
//     to the historical relative timers.

import (
	"context"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// firstTokenRemainingSince is the leftover request-absolute first-CONTENT
// budget. A zero receivedAt falls back to the full deadline so callers that
// never stamp RequestTiming keep the historical relative timers.
func firstTokenRemainingSince(receivedAt time.Time, deadline time.Duration) time.Duration {
	if deadline <= 0 {
		return 0
	}
	if receivedAt.IsZero() {
		return deadline
	}
	remaining := deadline - time.Since(receivedAt)
	if remaining < 0 {
		return 0
	}
	return remaining
}

// timingReceivedAt reads ReceivedAt from a possibly-nil RequestTiming.
func timingReceivedAt(t *registry.RequestTiming) time.Time {
	if t == nil {
		return time.Time{}
	}
	return t.ReceivedAt
}

// firstTokenWriteContext bounds a provider write by the request-absolute
// first-token deadline. Provider WriteText blocks until the frame is on the
// wire and can wait behind an in-flight data write (the per-connection write
// watchdog allows 5-30s per frame); without this bound the budget can expire
// while the dispatch goroutine is still blocked on the write, letting the
// aggregator cancel before the loop can shed with a 429. The write lane
// honors context expiry without corrupting the connection (writeFrame never
// passes the context to the underlying WebSocket write).
func firstTokenWriteContext(ctx context.Context, receivedAt time.Time, deadline time.Duration) (context.Context, context.CancelFunc) {
	if receivedAt.IsZero() || deadline <= 0 {
		return ctx, func() {}
	}
	return context.WithDeadline(ctx, receivedAt.Add(deadline))
}

// providerAttributableStall reports whether a first-content timeout may feed
// per-provider fault breakers. True only when the provider was actually
// granted at least the preamble-content window and stayed silent. A wait
// capped short by the request-absolute clock is OUR deadline (queueing,
// admission, write congestion) — blaming it would quarantine healthy cold
// providers (two 504-coded feeds within 60s cool a pair for five minutes).
func providerAttributableStall(granted time.Duration) bool {
	return granted >= preambleContentTimeout
}

// drainReadyFirstContent consumes chunks ALREADY buffered on pr.ChunkCh
// without blocking. Boilerplate is held with the same cap semantics as the
// live wait arms; the first CONTENT chunk is returned. Deadline arms call
// this before declaring a first-token timeout: an on-time token that raced
// the (possibly zero-duration) timer must win, not be cancelled. A closed
// channel returns false — the timeout path's provider cleanup handles it.
func drainReadyFirstContent(pr *registry.PendingRequest, held *[]string) (string, bool) {
	if pr == nil {
		return "", false
	}
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if !ok {
				return "", false
			}
			if held != nil && len(*held) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				*held = append(*held, chunk)
				pr.MarkFirstChunkArrived()
				continue
			}
			return chunk, true
		default:
			return "", false
		}
	}
}

// takeBufferedGenericChunk non-blockingly claims a chunk already buffered on
// the generic (/v1/completions, /v1/messages) path, which has no preamble
// filter — the first chunk of ANY kind commits.
func takeBufferedGenericChunk(pr *registry.PendingRequest) (string, bool) {
	select {
	case chunk, ok := <-pr.ChunkCh:
		if ok {
			return chunk, true
		}
	default:
	}
	return "", false
}

// firstTokenRemaining is the leftover request-absolute first-CONTENT budget.
// ok is false when ReceivedAt was never stamped; callers then keep the
// historical relative timer (d.deadline / d.deadline-speculativeAt).
func (d *dispatchState) firstTokenRemaining() (remaining time.Duration, ok bool) {
	if d == nil || d.timing == nil || d.timing.ReceivedAt.IsZero() {
		return 0, false
	}
	return firstTokenRemainingSince(d.timing.ReceivedAt, d.deadline), true
}

// firstTokenWait returns how long we may still wait for first CONTENT.
// When the request clock is set this is leftover SLA from ReceivedAt,
// never a fresh relative window. relativeFallback is the pre-clock
// behavior (full deadline, leftover after speculative, or inferenceTimeout).
func (d *dispatchState) firstTokenWait(relativeFallback time.Duration) time.Duration {
	if remaining, ok := d.firstTokenRemaining(); ok {
		return remaining
	}
	if relativeFallback < 0 {
		return 0
	}
	return relativeFallback
}

func (d *dispatchState) firstTokenExpired() bool {
	remaining, ok := d.firstTokenRemaining()
	return ok && remaining == 0
}

func (d *dispatchState) canExtendPreambleLiveness() bool {
	return d.firstTokenWait(preambleContentTimeout) > 0
}

// firstTokenSpeculativeWait is how long to wait before launching a backup.
// With a request clock this is the leftover time until the absolute
// speculative point (ReceivedAt + speculativeAt), not a fresh relative
// delay. Past that point it is 0 so the backup starts immediately.
func (d *dispatchState) firstTokenSpeculativeWait() time.Duration {
	remaining, ok := d.firstTokenRemaining()
	if !ok {
		if d.speculativeAt < 0 {
			return 0
		}
		return d.speculativeAt
	}
	if remaining <= 0 {
		return 0
	}
	elapsed := d.deadline - remaining
	if elapsed < 0 {
		elapsed = 0
	}
	specWait := d.speculativeAt - elapsed
	if specWait < 0 {
		specWait = 0
	}
	if specWait > remaining {
		specWait = remaining
	}
	return specWait
}

// abandonInflightForFirstTokenTimeout cancels a request already on the wire
// when the request-absolute first-token clock is gone. Without this the
// exhausted ladder refunds the client while the provider keeps generating,
// retains the slot, and can later settle an already-rejected request. The
// terminal cause is OUR clock, so the last error is overridden with the
// synthetic 504 the exhausted ladder reclassifies to a retryable 429
// (first_chunk_timeout) — never a leaked 5xx from a prior attempt.
func (d *dispatchState) abandonInflightForFirstTokenTimeout() {
	if d == nil {
		return
	}
	d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
	if d.provider == nil || d.pr == nil {
		return
	}
	provider, pr := d.provider, d.pr
	d.excludeProviders[provider.ID] = struct{}{}
	d.s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
	d.s.cancelDispatch(provider, pr)
	d.updateRoutingOutcomeForAttempt(
		routingAttempt(provider, pr, d.requestID, d.attempt),
		d.errorRoutingOutcomeFor(pr, "timeout", "first_chunk_timeout", http.StatusGatewayTimeout),
	)
	if d.s.metrics != nil {
		d.s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
	}
	d.s.ddIncr("inference.dispatches", []string{"status:timeout"})
	d.provider = nil
	d.pr = nil
}
