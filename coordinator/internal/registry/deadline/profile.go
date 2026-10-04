// Package deadline owns reviewed first-content qualification evidence.
package deadline

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/firstcontent"
)

// Profile qualifies bounded first-content cells, never serving concurrency,
// whole-Mac charges, prefill policy or memory admission.
type Profile struct {
	ID                           string                       `json:"id"`
	ModelID                      string                       `json:"model_id"`
	ArtifactSHA256               string                       `json:"artifact_sha256"`
	ProviderVersion              string                       `json:"provider_version"`
	RuntimeRevision              string                       `json:"runtime_revision"`
	MTP                          *protocol.ServingMTPIdentity `json:"mtp,omitempty"`
	KVBackend                    string                       `json:"kv_backend"`
	ChipName                     string                       `json:"chip_name"`
	GPUCores                     uint32                       `json:"gpu_cores"`
	MemoryGB                     uint64                       `json:"memory_gb"`
	ConfiguredContextTokens      int                          `json:"configured_context_tokens"`
	EffectiveMaxConcurrency      int                          `json:"effective_max_concurrency"`
	PrefillChunkSize             int                          `json:"prefill_chunk_size"`
	SoloPrefillStripeTokens      *int                         `json:"solo_prefill_stripe_tokens,omitempty"`
	MaxConcurrentPartialPrefills int                          `json:"max_concurrent_partial_prefills"`
	MixedPrefillTokenCap         *int                         `json:"mixed_prefill_token_cap,omitempty"`
	MinimumWholeMacQuiescenceMS  *int                         `json:"minimum_whole_mac_quiescence_ms"`
	MinimumNominalStabilityMS    *int                         `json:"minimum_nominal_stability_ms"`
	PowerMode                    string                       `json:"power_mode"`
	QualificationReportSHA256    string                       `json:"qualification_report_sha256"`
	DeadlineCalibration          *firstcontent.Calibration    `json:"deadline_calibration"`
}

func (p *Profile) Valid() bool {
	valid := p != nil && p.ID != "" && len(p.ID) <= 256 && p.ModelID != "" &&
		performance.ValidDigest(p.ArtifactSHA256) && performance.ValidDigest(p.QualificationReportSHA256) &&
		p.ProviderVersion != "" && p.RuntimeRevision == performance.RuntimeRevision && performance.ValidMTPIdentity(p.MTP) &&
		(p.KVBackend == "paged" || p.KVBackend == "contiguous") && p.ChipName != "" && p.GPUCores > 0 && p.MemoryGB > 0 &&
		p.ConfiguredContextTokens > 0 && p.ConfiguredContextTokens <= 1<<20 &&
		p.EffectiveMaxConcurrency > 0 && p.EffectiveMaxConcurrency <= 16 &&
		p.PrefillChunkSize > 0 && p.PrefillChunkSize <= 1<<20 &&
		(p.SoloPrefillStripeTokens == nil || (*p.SoloPrefillStripeTokens > 0 && *p.SoloPrefillStripeTokens <= 1<<20)) &&
		p.MaxConcurrentPartialPrefills == 1 &&
		(p.MixedPrefillTokenCap == nil || *p.MixedPrefillTokenCap == 128 || *p.MixedPrefillTokenCap == 256 || *p.MixedPrefillTokenCap == 512) &&
		ValidApplicability(p.MinimumWholeMacQuiescenceMS, p.MinimumNominalStabilityMS, p.PowerMode) &&
		p.DeadlineCalibration.Valid(p.ConfiguredContextTokens)
	if !valid {
		return false
	}
	for _, cell := range p.DeadlineCalibration.Cells {
		if cell.MaxActiveRequests > p.EffectiveMaxConcurrency || cell.ReportSHA256 != p.QualificationReportSHA256 {
			return false
		}
	}
	return true
}

func (p *Profile) MeasuredContextTokensMax() int {
	limit := 0
	if p != nil && p.DeadlineCalibration != nil {
		for _, cell := range p.DeadlineCalibration.Cells {
			limit = max(limit, cell.ContextTokensMax)
		}
	}
	return limit
}

func ValidApplicability(quiescence, stability *int, powerMode string) bool {
	// Other windows require a new measured recovery policy, not edits to the
	// compiled release record.
	return quiescence != nil && *quiescence == 20000 &&
		stability != nil && *stability == 5000 && powerMode == "automatic"
}

func NominalPosture(capacity *protocol.BackendCapacity, metrics protocol.SystemMetrics) bool {
	return metrics.ThermalState == "nominal" && capacity != nil && capacity.Telemetry != nil &&
		capacity.Telemetry.LowPowerMode != nil && !*capacity.Telemetry.LowPowerMode
}
