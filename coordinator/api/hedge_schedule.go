package api

import "time"

// Hedge launch timing — the adaptive replacement for the bare
// speculativeTimerRatio point (Routing v2 Phase 4, timing half).
//
// Today the only hedge policy is "launch the backup at 50% of the deadline"
// (consumer.go speculativeTimerRatio). That point is blind to the backup: a
// backup whose own q90 TTFT is 6s launched at the 50% point of a 9s budget can
// NEVER produce first content before the clock dies — the coordinator burns a
// second provider's compute to buy zero insurance. The fix is to launch no
// later than the last instant the backup can still plausibly win:
//
//	latest_useful = deadline - max(backup_ttft_q90, floor) - commit_guard
//	hedge_offset  = min(deadline * 1/2, latest_useful), floored at 0
//
// Invariants (each is load-bearing; wave-2 wiring and tests rely on them):
//
//  1. The offset is NEVER later than the 50% point. A fast-quoted backup only
//     moves the launch EARLIER; a missing/low-confidence quote collapses to
//     exactly the historical 50% behavior, so the legacy path is the ceiling,
//     never exceeded.
//  2. The absolute first-content deadline is never extended. The offset is
//     measured from ReceivedAt inside the existing clock
//     (first_token_clock.go invariant 1); a launch time in the past means
//     "launch immediately", never "add time".
//  3. Pure function of its inputs — no clocks read, no state, so the same
//     (deadline, quote) pair always schedules identically and the property
//     tests can sweep it exhaustively. Model-specific deadlines (#787,
//     Server.FirstContentDeadline) arrive as the deadline parameter; nothing
//     here hardcodes a budget.

const (
	// hedgeCommitGuard is subtracted from the backup's usable window so its
	// first content can still clear commitFirstContent, the response write,
	// and channel handoff before the absolute clock dies. Recent timeout
	// route rows show coordinator-side commit+write overhead well under this;
	// 500ms keeps a whole scheduling quantum of slack without eating into
	// launch-earlier headroom on the ordinary 9s budget.
	hedgeCommitGuard = 500 * time.Millisecond

	// hedgeMinBackupBudget is the floor on the backup TTFT term. A quote can
	// legitimately report a q90 of tens of milliseconds (warm slot, idle box),
	// but granting the backup less than a second of runway makes the launch
	// point degenerate — latest_useful drifts toward the deadline itself and
	// the "insurance" becomes a last-millisecond dispatch that mostly loses
	// while still consuming a second provider. One second is the smallest
	// window in which a warm provider observably produces first content.
	hedgeMinBackupBudget = time.Second

	// hedgeRatioDenominator expresses the 50% ceiling as
	// integer duration math (deadline/2) so the collapse point is exactly the
	// historical speculativeTimerRatio point, bit-for-bit, with no float
	// rounding drift between the legacy and adaptive paths.
	hedgeRatioDenominator = 2
)

// hedgeQuoteConfidence grades the backup TTFT estimate feeding the schedule.
// Quote-capable providers report high|low on capacity_quote; legacy/unconfirmed
// plan entries have no quote at all (none). Only a high-confidence measured
// quote may move the launch point off the 50% ceiling: acting on a low-trust
// number could only move the launch EARLIER (invariant 1), and launching early
// on bad data is exactly the compute amplification the governor exists to
// prevent.
type hedgeQuoteConfidence int

const (
	// hedgeConfidenceNone: no quote (legacy provider, probe timeout, or
	// unconfirmed plan entry). Schedule at the historical 50% point.
	hedgeConfidenceNone hedgeQuoteConfidence = iota
	// hedgeConfidenceLow: the provider quoted from a sparse/fallback bucket
	// (model→chip aggregate→benchmark manifest). Treated as none.
	hedgeConfidenceLow
	// hedgeConfidenceHigh: quoted from a populated per-(model, warm/cold,
	// bucket) end-to-end TTFT ring of completed real requests.
	hedgeConfidenceHigh
)

// hedgeLaunchOffset computes how long after ReceivedAt the backup dispatch may
// launch. deadline is the request-absolute first-content budget for the
// concrete model (Server.FirstContentDeadline(model, promptTokens) — 9s+1ms/tok
// ordinary, tightened by exact-model policy). backupTTFTQ90 is the backup's
// calibrated end-to-end q90 estimate; it participates only at high confidence.
// A non-positive deadline (zero value, expired upstream) schedules immediate
// launch — the caller's dispatch clock, not this function, decides whether any
// dispatch still fits.
func hedgeLaunchOffset(
	deadline time.Duration,
	backupTTFTQ90 time.Duration,
	confidence hedgeQuoteConfidence,
) time.Duration {
	if deadline <= 0 {
		return 0
	}
	halfPoint := deadline / hedgeRatioDenominator
	if confidence != hedgeConfidenceHigh {
		return halfPoint
	}
	backupBudget := backupTTFTQ90
	if backupBudget < hedgeMinBackupBudget {
		backupBudget = hedgeMinBackupBudget
	}
	latestUseful := deadline - backupBudget - hedgeCommitGuard
	offset := halfPoint
	if latestUseful < offset {
		offset = latestUseful
	}
	if offset < 0 {
		// The backup can no longer win even if launched now; launch
		// immediately and let the race decide, never wait past a point
		// that is already gone.
		offset = 0
	}
	return offset
}

// hedgeLaunchAt anchors the offset on the request-absolute clock: the wall
// time at which the backup may launch, receivedAt + offset. It inherits every
// hedgeLaunchOffset invariant; in particular the result never exceeds
// receivedAt + deadline/2, so it can never extend the absolute deadline.
// Callers with an unstamped ReceivedAt (unit tests, mixed-version paths) keep
// using the relative offset directly, mirroring first_token_clock.go
// invariant 5.
func hedgeLaunchAt(
	receivedAt time.Time,
	deadline time.Duration,
	backupTTFTQ90 time.Duration,
	confidence hedgeQuoteConfidence,
) time.Time {
	return receivedAt.Add(hedgeLaunchOffset(deadline, backupTTFTQ90, confidence))
}
