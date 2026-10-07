package observation

import metriclabels "github.com/eigeninference/d-inference/coordinator/internal/observation/labels"

type MetricLabel = metriclabels.MetricLabel

func LowCardinalityCacheTier(tier string) string { return metriclabels.LowCardinalityCacheTier(tier) }
