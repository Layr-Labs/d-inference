package registry

import "github.com/eigeninference/d-inference/coordinator/internal/registry/performance"

type servingBatchPoint = performance.BatchPoint

// Release-reviewed data mirrors ServingPerformanceProfile in Swift. The
// content-addressed qualification report owns the complete workload matrix.
type servingPerformanceProfile performance.Profile

func (profile *servingPerformanceProfile) batchAt(width int) (servingBatchPoint, bool) {
	return (*performance.Profile)(profile).BatchAt(width)
}

// concurrencyForDecodeFloor uses the same conservative point as projected
// decode: intermediate operator caps borrow only the next measured width's p10.
// A floor above even B1 retains the existing single-request fallback.
func (profile *servingPerformanceProfile) concurrencyForDecodeFloor(limit int, floor float64) int {
	return (*performance.Profile)(profile).ConcurrencyForDecodeFloor(limit, floor)
}

// Caller holds p.mu. A heartbeat names the reviewed record; it supplies no
// trusted rates or qualification claims. Missing exact identity means legacy.
func qualifiedPerformanceProfileLocked(p *Provider, model string) *servingPerformanceProfile {
	return (*servingPerformanceProfile)(p.performanceProfiles.Qualified(performance.Identity{
		Version: p.Version, Hardware: p.Hardware, Models: p.Models, Capacity: p.BackendCapacity,
		ThermalState: p.SystemMetrics.ThermalState,
	}, model))
}
