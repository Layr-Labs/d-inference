package firstcontent

import (
	"context"
	"time"

	inresp "github.com/eigeninference/d-inference/coordinator/api/inference/response"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// firstTokenRemainingSince is the leftover request-absolute first-CONTENT
// budget. A zero receivedAt falls back to the full deadline so callers that
// never stamp RequestTiming keep the historical relative timers.
func FirstTokenRemainingSince(receivedAt time.Time, deadline time.Duration) time.Duration {
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

// firstContentBudgetMillis converts the request-absolute first-content clock to
// the optional positive integer carried on an inference_request. A missing
// ReceivedAt preserves mixed-version and unit-test behavior by omitting the
// field without blocking dispatch. A real clock that has expired blocks the
// send. Positive sub-millisecond remainders are represented as 1ms: zero means
// "field absent" on the wire and must never accidentally disable the deadline.
func FirstContentBudgetMillis(receivedAt time.Time, deadline time.Duration) (budgetMS int64, dispatchable bool) {
	if receivedAt.IsZero() || deadline <= 0 {
		return 0, true
	}
	remaining := FirstTokenRemainingSince(receivedAt, deadline)
	if remaining <= 0 {
		return 0, false
	}
	budgetMS = remaining.Milliseconds()
	if budgetMS < 1 {
		budgetMS = 1
	}
	return budgetMS, true
}

// timingReceivedAt reads ReceivedAt from a possibly-nil RequestTiming.
func TimingReceivedAt(t *registry.RequestTiming) time.Time {
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
// aggregator cancel before the loop can shed with a 429. Cancellation before
// socket handoff discards the frame; cancellation during a socket write closes
// the connection so a partial or late request can never be reused.
func FirstTokenWriteContext(ctx context.Context, receivedAt time.Time, deadline time.Duration) (context.Context, context.CancelFunc) {
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
	return granted >= PreambleContentTimeout
}

func ProviderAttemptAttributableStall(
	pr *registry.PendingRequest,
	fallbackGranted time.Duration,
) bool {
	granted := fallbackGranted
	if pr != nil && pr.Timing != nil && !pr.Timing.DispatchedAt.IsZero() {
		granted = time.Since(pr.Timing.DispatchedAt)
	}
	return providerAttributableStall(granted)
}

// holdPreContentBoilerplate reports whether a chunk must not commit first
// content. It retains bounded boilerplate, and drops content whose coordinator
// ingress timestamp is after the request-absolute deadline. A zero ingress time
// is accepted only for synthetic tests; production chunks are always stamped.
func HoldPreContentBoilerplate(
	pr *registry.PendingRequest,
	chunk registry.ProviderChunk,
	held *[]string,
) bool {
	if pr != nil {
		pr.MarkFirstChunkArrived()
	}
	if !inresp.IsBoilerplateChunk(chunk.Data) {
		return pr != nil &&
			!pr.FirstContentDeadline.IsZero() &&
			!chunk.ReceivedAt.IsZero() &&
			chunk.ReceivedAt.After(pr.FirstContentDeadline)
	}
	if held != nil && len(*held) < maxHeldBoilerplate {
		*held = append(*held, chunk.Data)
	}
	return true
}

// drainReadyFirstContent consumes chunks ALREADY buffered on pr.ChunkCh
// without blocking. Boilerplate is held with the same cap semantics as the
// live wait arms; the first on-deadline CONTENT chunk is returned. Deadline
// arms call this before declaring a first-token timeout: an on-time token that
// raced the (possibly zero-duration) timer must win, while a post-deadline token
// must not. A closed channel returns false — the timeout path cleans it up.
func DrainReadyFirstContent(
	pr *registry.PendingRequest,
	held *[]string,
) (registry.ProviderChunk, bool) {
	if pr == nil {
		return registry.ProviderChunk{}, false
	}
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if !ok {
				return registry.ProviderChunk{}, false
			}
			if HoldPreContentBoilerplate(pr, chunk, held) {
				continue
			}
			return chunk, true
		default:
			return registry.ProviderChunk{}, false
		}
	}
}
