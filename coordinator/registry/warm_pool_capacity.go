package registry

import "github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"

// warmPoolCapacityLocked resolves each Mac's qualified curve before taking
// fleet medians. A median of unrelated solo rates and caps can describe no real
// machine. Unknown profiles retain the existing quality-concurrency policy.
func (r *Registry) warmPoolCapacityLocked(p *Provider, model string, params warmplan.TargetParams) (quality int, aggregateDecode, prefill float64) {
	decode, prefill := resolvedModelTPSLocked(p, model)
	limit := p.maxConcurrencyForModelLocked(model)
	quality = warmplan.QualityConcurrency(r.resolvedSoloModelTPSLocked(p, model).tps, params.DecodeFloorTPS, params.LoadFactorK, limit, params.FallbackQualityConcurrency)
	aggregateDecode = decode * float64(quality)
	if profile := qualifiedPerformanceProfileLocked(p, model); profile != nil {
		cap := profile.concurrencyForDecodeFloor(limit, params.DecodeFloorTPS)
		if point, ok := profile.batchAt(cap); ok && cap > 0 {
			quality = cap
			aggregateDecode = point.AggregateDecodeTPS
			if point.Width != cap {
				// An operator cap between qualified widths cannot inherit the
				// larger width's aggregate throughput.
				aggregateDecode = point.DecodeP10TPS * float64(cap)
			}
			prefill = point.PrefillTPS
		}
	}
	return quality, aggregateDecode, prefill
}
