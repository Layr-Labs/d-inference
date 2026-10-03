package api

// Routing v2 wave-2 dispatch wiring: the dispatchState half of the bounded
// plan (registry/dispatch_plan.go), the parallel capacity-probe round
// (registry/capacity_quotes.go), and the hedge governor/schedule
// (hedge_governor.go / hedge_schedule.go).
//
// Shape of the flow:
//
//	dispatchPrimary        — full scan retains the plan; after the primary
//	                         frame handoff, ONE probe round confirms/demotes
//	                         the alternates in parallel with the prompt.
//	waitFirstChunk         — may re-arm the speculative timer EARLIER when the
//	                         probe round proves the 50% point launches a backup
//	                         too late to win (hedgeLaunchAt).
//	runSpeculative         — the governor gates the launch; an admitted backup
//	                         consumes the plan before any rescan.
//	run (failover retries) — next attempts consume the plan before any rescan;
//	                         one RefreshDispatchPlan per logical request.
//
// Missing plans use full-scan selection under the same first-content and
// ownership policy. Probes require a retained plan; every hedge still needs
// credible feasible evidence and spare service allowance at reservation.
