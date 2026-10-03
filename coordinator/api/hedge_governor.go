package api

// Hedge governor — the admission half of Routing v2 Phase 4: insurance that
// cannot amplify an overload.
//
// Production evidence this exists to answer: the measured spread failure is
// occupancy HERDING, not lack of diversity — idle loaded boxes coexisted with
// 100% of the gpt-oss cancels (registry/ttft_shadow.go), while recent timeout
// route rows carried candidate counts of 86-401. Hedges launched into that
// herd make it strictly worse: each hedge occupies a second slot for the same
// request, occupancy rises, TTFT estimates degrade, more requests look slow,
// more hedges launch — the classic congestion-collapse spiral. Every rule
// below is a brake on that loop; a hedge is pure insurance and insurance must
// never outrank real demand.
//
// The verdict is a pure function of a point-in-time inputs snapshot so it can
// be tested exhaustively and attributed in telemetry: each suppression
// increments routing.hedge_governor_suppressed tagged with the verdict string
// and logs speculative_backup_suppressed. The mutable half — the global
// active-hedge counter and per-model win-rate EWMAs — lives in hedgeGovernor,
// whose tryAcquireHedge computes the verdict AND claims the budget slot under
// ONE mutex hold; dispatch wiring (acquire on launch, release on resolve,
// registry snapshot into inputs) lives in runSpeculative and
// dispatch_plan_wiring.go tryAcquireBackupHedge.
