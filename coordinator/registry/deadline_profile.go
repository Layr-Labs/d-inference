package registry

import "github.com/eigeninference/d-inference/coordinator/internal/registry/deadline"

// deadlinePerformanceProfile qualifies only bounded first-content cells. The
// configured context is exact runtime identity, not a claim that every context
// or batch width was measured. This record cannot change serving concurrency,
// whole-Mac charges, prefill policy, or memory admission.
type deadlinePerformanceProfile = deadline.Profile

// Caller holds p.mu. A reference identifies immutable release evidence; live
// telemetry cannot create its own calibration or borrow another scheduler.
func qualifiedDeadlineProfileLocked(p *Provider, model string) *deadlinePerformanceProfile {
	return (*deadlinePerformanceProfile)(p.deadlineProfiles.Qualified(deadline.Identity{Version: p.Version, Hardware: p.Hardware, Models: p.Models, Capacity: p.BackendCapacity, Metrics: p.SystemMetrics}, model))
}
