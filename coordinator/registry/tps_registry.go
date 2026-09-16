package registry

import "github.com/eigeninference/d-inference/coordinator/registry/throughput"

// TPSRegistry is the observed-rate owner used by heartbeat ingestion and routing.
// Its sample buffers, aggregate caches and mutex live in throughput.
type TPSRegistry = throughput.Observations

func NewTPSRegistry() *TPSRegistry { return throughput.NewObservations() }

// qualityConcurrency keeps admission's existing call surface while the batch
// degradation policy has one owner shared with warm-pool planning.
func qualityConcurrency(soloDecodeTPS, floor, k float64, maxProviderConc, fallbackConc int) int {
	return throughput.QualityConcurrency(soloDecodeTPS, floor, k, maxProviderConc, fallbackConc)
}
