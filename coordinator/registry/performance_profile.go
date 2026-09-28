package registry

import "math"

const servingPerformanceRuntimeRevision = "cbv2-first-content-v1"

type servingBatchPoint struct {
	Width              int     `json:"width"`
	DecodeP10TPS       float64 `json:"decode_p10_tps"`
	AggregateDecodeTPS float64 `json:"aggregate_decode_tps"`
	PrefillTPS         float64 `json:"prefill_tps"`
	FirstContentP95MS  float64 `json:"first_content_p95_ms"`
}

// Release-reviewed data mirrors ServingPerformanceProfile in Swift. The
// content-addressed qualification report owns the complete workload matrix.
type servingPerformanceProfile struct {
	ID                        string              `json:"id"`
	ModelID                   string              `json:"model_id"`
	ArtifactSHA256            string              `json:"artifact_sha256"`
	ProviderVersion           string              `json:"provider_version"`
	RuntimeRevision           string              `json:"runtime_revision"`
	KVBackend                 string              `json:"kv_backend"`
	ChipName                  string              `json:"chip_name"`
	GPUCores                  uint32              `json:"gpu_cores"`
	MemoryGB                  uint64              `json:"memory_gb"`
	ContextTokensMax          int                 `json:"context_tokens_max"`
	MaxConcurrency            int                 `json:"max_concurrency"`
	WholeMacConcurrency       int                 `json:"whole_mac_concurrency"`
	MixedPrefillTokenCap      *int                `json:"mixed_prefill_token_cap,omitempty"`
	QualificationReportSHA256 string              `json:"qualification_report_sha256"`
	BatchCurve                []servingBatchPoint `json:"batch_curve"`
}

// No hardware/profile expansion is implied by the historical M4 B8 report.
// Promotion requires matching reviewed entries in this and the Swift catalog.
var reviewedServingPerformanceProfiles = map[string]*servingPerformanceProfile{}

func (profile *servingPerformanceProfile) batchAt(width int) (servingBatchPoint, bool) {
	if profile == nil || width < 1 || width > profile.MaxConcurrency {
		return servingBatchPoint{}, false
	}
	for _, point := range profile.BatchCurve {
		if point.Width >= width {
			return point, true
		}
	}
	return servingBatchPoint{}, false
}

func (profile *servingPerformanceProfile) valid() bool {
	if profile == nil || profile.ID == "" || profile.ModelID == "" ||
		!validProfileDigest(profile.ArtifactSHA256) || !validProfileDigest(profile.QualificationReportSHA256) ||
		profile.ProviderVersion == "" || profile.RuntimeRevision != servingPerformanceRuntimeRevision ||
		(profile.KVBackend != "paged" && profile.KVBackend != "contiguous") ||
		profile.ChipName == "" || profile.GPUCores == 0 || profile.MemoryGB == 0 || profile.ContextTokensMax <= 0 ||
		profile.MaxConcurrency < 1 || profile.MaxConcurrency > 16 ||
		profile.WholeMacConcurrency < profile.MaxConcurrency || profile.WholeMacConcurrency > 16 ||
		len(profile.BatchCurve) == 0 || profile.BatchCurve[0].Width != 1 ||
		profile.BatchCurve[len(profile.BatchCurve)-1].Width != profile.MaxConcurrency {
		return false
	}
	if cap := profile.MixedPrefillTokenCap; cap != nil && (*cap < 128 || *cap > 512) {
		return false
	}
	previousWidth, previousThroughput := 0, 0.0
	for _, point := range profile.BatchCurve {
		if point.Width <= previousWidth || point.Width > profile.MaxConcurrency ||
			!finitePositive(point.DecodeP10TPS) || point.DecodeP10TPS < 30 ||
			!finitePositive(point.AggregateDecodeTPS) || !finitePositive(point.PrefillTPS) || point.PrefillTPS > 20000 ||
			!finitePositive(point.FirstContentP95MS) || point.FirstContentP95MS > math.Max(3000, 1.5*profile.BatchCurve[0].FirstContentP95MS) ||
			(previousWidth != 0 && point.AggregateDecodeTPS < previousThroughput*1.1) {
			return false
		}
		previousWidth, previousThroughput = point.Width, point.AggregateDecodeTPS
	}
	return true
}

func validProfileDigest(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, c := range value {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

// Caller holds p.mu. A heartbeat names the reviewed record; it supplies no
// trusted rates or qualification claims. Missing exact identity means legacy.
func qualifiedPerformanceProfileLocked(p *Provider, model string) *servingPerformanceProfile {
	if p.BackendCapacity == nil || (p.SystemMetrics.ThermalState != "" && p.SystemMetrics.ThermalState != "nominal") {
		return nil
	}
	for _, slot := range p.BackendCapacity.Slots {
		if slot.Model != model || slot.PerformanceProfile == nil || slot.KVBackend == nil {
			continue
		}
		ref := slot.PerformanceProfile
		profile := reviewedServingPerformanceProfiles[ref.ID]
		if !profile.valid() || profile.ModelID != model || profile.ProviderVersion != p.Version ||
			profile.RuntimeRevision != ref.RuntimeRevision || profile.KVBackend != *slot.KVBackend ||
			profile.ChipName != p.Hardware.ChipName || uint64(profile.GPUCores) != uint64(p.Hardware.GPUCores) ||
			profile.MemoryGB != uint64(p.Hardware.MemoryGB) || ref.ContextTokens <= 0 || ref.ContextTokens > profile.ContextTokensMax {
			return nil
		}
		for _, info := range p.Models {
			if info.ID == model && info.WeightHash == profile.ArtifactSHA256 {
				return profile
			}
		}
	}
	return nil
}
