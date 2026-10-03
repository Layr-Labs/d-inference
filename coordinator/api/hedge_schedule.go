package api

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
