package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/firstcontent"
)

// deadlinePerformanceProfile qualifies only bounded first-content cells. The
// configured context is exact runtime identity, not a claim that every context
// or batch width was measured. This record cannot change serving concurrency,
// whole-Mac charges, prefill policy, or memory admission.
type deadlinePerformanceProfile struct {
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

// Only independently reviewed measured records may be promoted. This catalog
// is deliberately separate from universal batch/concurrency qualification.
var reviewedDeadlinePerformanceProfiles = decodeDeadlineProfileCatalog(reviewedDeadlineProfilesJSON)

func (p *deadlinePerformanceProfile) valid() bool {
	valid := p != nil && p.ID != "" && len(p.ID) <= 256 && p.ModelID != "" &&
		validProfileDigest(p.ArtifactSHA256) && validProfileDigest(p.QualificationReportSHA256) &&
		p.ProviderVersion != "" && p.RuntimeRevision == servingPerformanceRuntimeRevision && validMTPIdentity(p.MTP) &&
		(p.KVBackend == "paged" || p.KVBackend == "contiguous") && p.ChipName != "" && p.GPUCores > 0 && p.MemoryGB > 0 &&
		p.ConfiguredContextTokens > 0 && p.ConfiguredContextTokens <= 1<<20 &&
		p.EffectiveMaxConcurrency > 0 && p.EffectiveMaxConcurrency <= 16 &&
		p.PrefillChunkSize > 0 && p.PrefillChunkSize <= 1<<20 &&
		(p.SoloPrefillStripeTokens == nil || (*p.SoloPrefillStripeTokens > 0 && *p.SoloPrefillStripeTokens <= 1<<20)) &&
		p.MaxConcurrentPartialPrefills == 1 &&
		(p.MixedPrefillTokenCap == nil || *p.MixedPrefillTokenCap == 128 || *p.MixedPrefillTokenCap == 256 || *p.MixedPrefillTokenCap == 512) &&
		validDeadlineApplicability(p.MinimumWholeMacQuiescenceMS, p.MinimumNominalStabilityMS, p.PowerMode) &&
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

func (p *deadlinePerformanceProfile) measuredContextTokensMax() int {
	limit := 0
	if p != nil && p.DeadlineCalibration != nil {
		for _, cell := range p.DeadlineCalibration.Cells {
			limit = max(limit, cell.ContextTokensMax)
		}
	}
	return limit
}

// Caller holds p.mu. A reference identifies immutable release evidence; live
// telemetry cannot create its own calibration or borrow another scheduler.
func qualifiedDeadlineProfileLocked(p *Provider, model string) *deadlinePerformanceProfile {
	if !deadlineNominalPosture(p.BackendCapacity, p.SystemMetrics) {
		return nil
	}
	for _, slot := range p.BackendCapacity.Slots {
		if slot.Model != model || slot.DeadlineProfile == nil || slot.KVBackend == nil {
			continue
		}
		ref := slot.DeadlineProfile
		profile := reviewedDeadlinePerformanceProfiles[ref.ID]
		if !profile.valid() || profile.ModelID != model || profile.ProviderVersion != p.Version ||
			profile.RuntimeRevision != ref.RuntimeRevision || !profile.MTP.Equal(ref.MTP) || profile.KVBackend != *slot.KVBackend ||
			profile.ChipName != p.Hardware.ChipName || uint64(profile.GPUCores) != uint64(p.Hardware.GPUCores) ||
			profile.MemoryGB != uint64(p.Hardware.MemoryGB) || profile.ConfiguredContextTokens != ref.ConfiguredContextTokens ||
			profile.EffectiveMaxConcurrency != ref.EffectiveMaxConcurrency || profile.PrefillChunkSize != ref.PrefillChunkSize ||
			!sameOptionalInt(profile.SoloPrefillStripeTokens, ref.SoloPrefillStripeTokens) ||
			profile.MaxConcurrentPartialPrefills != ref.MaxConcurrentPartialPrefills || !sameOptionalInt(profile.MixedPrefillTokenCap, ref.MixedPrefillTokenCap) ||
			!sameOptionalInt(profile.MinimumWholeMacQuiescenceMS, ref.MinimumWholeMacQuiescenceMS) ||
			!sameOptionalInt(profile.MinimumNominalStabilityMS, ref.MinimumNominalStabilityMS) || profile.PowerMode != ref.PowerMode {
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

func sameOptionalInt(a, b *int) bool {
	return (a == nil && b == nil) || (a != nil && b != nil && *a == *b)
}
