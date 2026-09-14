package registry

import "github.com/eigeninference/d-inference/coordinator/registry/throughput"

// These names preserve the registry API while throughput owns policy and math.
// Keep the table variables as inputs to each call: callers replacing a legacy
// map must observe their replacement just as callers mutating its entries do.
type ModelDecodeClass = throughput.ModelDecodeClass
type ThroughputAnomalyConfig = throughput.AnomalyConfig
type ThroughputAnomalyInput = throughput.AnomalyInput
type ThroughputAnomalyResult = throughput.AnomalyResult

const (
	BytesPerParam4Bit            = throughput.BytesPerParam4Bit
	BytesPerParam8Bit            = throughput.BytesPerParam8Bit
	BytesPerParamBF16            = throughput.BytesPerParamBF16
	DefaultDecodeEfficiency      = throughput.DefaultDecodeEfficiency
	DefaultAnomalyRatioThreshold = throughput.DefaultAnomalyRatioThreshold
	DefaultAnomalyMinSamples     = throughput.DefaultAnomalyMinSamples
)

var (
	ModelDecodeClasses = throughput.DefaultPolicy().Models
	ChipBandwidthGBps  = throughput.DefaultPolicy().ChipBandwidth
)

func throughputPolicy() throughput.Policy {
	return throughput.Policy{Models: ModelDecodeClasses, ChipBandwidth: ChipBandwidthGBps}
}

func ExpectedDecodeTPS(activeParams, bytesPerParam, bandwidthGBps, efficiency float64) float64 {
	return throughput.ExpectedDecodeTPS(activeParams, bytesPerParam, bandwidthGBps, efficiency)
}
func LookupModelDecodeClass(model string) (ModelDecodeClass, bool) {
	return throughputPolicy().LookupModelDecodeClass(model)
}
func BytesPerParamForModelID(model string) float64 {
	return throughput.BytesPerParamForModelID(model)
}
func NormalizeChipClass(family, tier string) string {
	return throughput.NormalizeChipClass(family, tier)
}
func ResolveChipClass(family, tier, chipName string) string {
	return throughput.ResolveChipClass(family, tier, chipName)
}
func ChipBandwidthForClass(class string) float64 {
	return throughputPolicy().ChipBandwidthForClass(class)
}
func DefaultThroughputAnomalyConfig() ThroughputAnomalyConfig {
	return throughput.DefaultAnomalyConfig()
}
func EvaluateThroughputAnomaly(in ThroughputAnomalyInput, cfg ThroughputAnomalyConfig) ThroughputAnomalyResult {
	return throughputPolicy().EvaluateAnomaly(in, cfg)
}
