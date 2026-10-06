// Package performance resolves release-reviewed serving curves by exact identity.
package performance

import (
	"math"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const RuntimeRevision = "cbv2-first-content-v2"

type BatchPoint struct {
	Width              int     `json:"width"`
	DecodeP10TPS       float64 `json:"decode_p10_tps"`
	AggregateDecodeTPS float64 `json:"aggregate_decode_tps"`
	PrefillTPS         float64 `json:"prefill_tps"`
	FirstContentP95MS  float64 `json:"first_content_p95_ms"`
}

// Profile mirrors the release-reviewed ServingPerformanceProfile in Swift.
// Its content-addressed qualification report owns the full workload matrix.
type Profile struct {
	ID                        string                       `json:"id"`
	ModelID                   string                       `json:"model_id"`
	ArtifactSHA256            string                       `json:"artifact_sha256"`
	ProviderVersion           string                       `json:"provider_version"`
	RuntimeRevision           string                       `json:"runtime_revision"`
	MTP                       *protocol.ServingMTPIdentity `json:"mtp,omitempty"`
	KVBackend                 string                       `json:"kv_backend"`
	ChipName                  string                       `json:"chip_name"`
	GPUCores                  uint32                       `json:"gpu_cores"`
	MemoryGB                  uint64                       `json:"memory_gb"`
	ContextTokensMax          int                          `json:"context_tokens_max"`
	MaxConcurrency            int                          `json:"max_concurrency"`
	WholeMacConcurrency       int                          `json:"whole_mac_concurrency"`
	MixedPrefillTokenCap      *int                         `json:"mixed_prefill_token_cap,omitempty"`
	QualificationReportSHA256 string                       `json:"qualification_report_sha256"`
	BatchCurve                []BatchPoint                 `json:"batch_curve"`
}

func (profile *Profile) BatchAt(width int) (BatchPoint, bool) {
	if profile == nil || width < 1 || width > profile.MaxConcurrency {
		return BatchPoint{}, false
	}
	for _, point := range profile.BatchCurve {
		if point.Width >= width {
			return point, true
		}
	}
	return BatchPoint{}, false
}

// Intermediate operator caps borrow only the next measured width's p10. A
// floor above even B1 retains the existing single-request fallback.
func (profile *Profile) ConcurrencyForDecodeFloor(limit int, floor float64) int {
	limit = min(max(1, limit), profile.MaxConcurrency, profile.WholeMacConcurrency)
	if floor <= 0 {
		return limit
	}
	for width := limit; width > 1; width-- {
		if point, ok := profile.BatchAt(width); ok && point.DecodeP10TPS >= floor {
			return width
		}
	}
	return 1
}

func (profile *Profile) Valid() bool {
	if profile == nil || profile.ID == "" || profile.ModelID == "" ||
		!ValidDigest(profile.ArtifactSHA256) || !ValidDigest(profile.QualificationReportSHA256) ||
		profile.ProviderVersion == "" || profile.RuntimeRevision != RuntimeRevision ||
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
	if !ValidMTPIdentity(profile.MTP) {
		return false
	}
	previousWidth, previousThroughput := 0, 0.0
	for _, point := range profile.BatchCurve {
		if point.Width <= previousWidth || point.Width > profile.MaxConcurrency ||
			!capacityvalue.FinitePositive(point.DecodeP10TPS) || point.DecodeP10TPS < 30 ||
			!capacityvalue.FinitePositive(point.AggregateDecodeTPS) || !capacityvalue.FinitePositive(point.PrefillTPS) || point.PrefillTPS > 20000 ||
			!capacityvalue.FinitePositive(point.FirstContentP95MS) || point.FirstContentP95MS > math.Max(3000, 1.5*profile.BatchCurve[0].FirstContentP95MS) ||
			(previousWidth != 0 && point.AggregateDecodeTPS < previousThroughput*1.1) {
			return false
		}
		previousWidth, previousThroughput = point.Width, point.AggregateDecodeTPS
	}
	return true
}

func ValidDigest(value string) bool {
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

func validMTPVerificationMode(mode string) bool {
	switch mode {
	case "serial_target", "rectangular", "rectangular_exact", "automatic":
		return true
	default:
		return false
	}
}

func ValidMTPIdentity(mtp *protocol.ServingMTPIdentity) bool {
	return mtp == nil || (mtp.Enabled && ValidDigest(mtp.ArtifactSHA256) && mtp.MaxDraftTokens >= 0 && mtp.MaxDraftTokens <= 7 &&
		mtp.MaxSpeculativeBatch >= 1 && mtp.MaxSpeculativeBatch <= 8 && validMTPVerificationMode(mtp.VerificationMode) &&
		mtp.MaxAutomaticRectangularTokens >= 0 && (mtp.FixedDraftTokens == nil || (*mtp.FixedDraftTokens >= 0 && *mtp.FixedDraftTokens <= mtp.MaxDraftTokens)))
}
