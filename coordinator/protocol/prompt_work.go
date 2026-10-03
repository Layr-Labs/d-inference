package protocol

const (
	PromptWorkVersion    = 1
	PromptWorkExact      = "exact_contract"
	PromptWorkCalibrated = "calibrated_template"
	PromptWorkHeuristic  = "heuristic"
	MaxPromptWorkTokens  = 1_048_576
)

// PromptWork describes numeric input work, never prompt content or cache keys.
// Only exact contract counts or reviewed calibration can supply an upper bound.
// A heuristic remains explicitly unqualified, even if it has a numeric estimate.
// The coordinator may reconcile the SLA token term from a verified exact count
// before dispatch, retaining the ingress anchor and earlier caller cutoff.
// Calibration uncertainty and provider recount cannot extend the inherited
// deadline; count evidence never changes billing usage.
type PromptWork struct {
	Version           int    `json:"version"`
	Source            string `json:"source"`
	PromptTokens      int    `json:"prompt_tokens"`
	UpperBoundTokens  int    `json:"upper_bound_tokens"`
	PromptContractID  string `json:"prompt_contract_id,omitempty"`
	ModelArtifactHash string `json:"model_artifact_hash,omitempty"`
	CalibrationID     string `json:"calibration_id,omitempty"`
}

// PromptWorkIdentity describes the artifact and renderer contract actually used
// by one loaded engine. It is independent of prefix-cache enablement.
type PromptWorkIdentity struct {
	ModelArtifactHash string `json:"model_artifact_hash"`
	PromptContractID  string `json:"prompt_contract_id"`
}

func (p *PromptWorkIdentity) IsValid() bool {
	return p != nil && promptWorkDigest(p.ModelArtifactHash) && promptWorkDigest(p.PromptContractID)
}

func (p *PromptWorkIdentity) Clone() *PromptWorkIdentity {
	if p == nil {
		return nil
	}
	copy := *p
	return &copy
}

// IsQualifiedFor binds the count to the same artifact and rendered-template
// contract advertised by the candidate provider. Unknown versions and provenance fail
// closed to ordinary estimation; they never make inference itself unavailable.
func (p *PromptWork) IsQualifiedFor(modelArtifactHash, promptContractID string) bool {
	if p == nil || p.Version != PromptWorkVersion || p.PromptTokens <= 0 ||
		p.UpperBoundTokens < p.PromptTokens || p.UpperBoundTokens > MaxPromptWorkTokens ||
		!promptWorkDigest(p.ModelArtifactHash) || !promptWorkDigest(p.PromptContractID) ||
		p.ModelArtifactHash != modelArtifactHash || p.PromptContractID != promptContractID {
		return false
	}
	switch p.Source {
	case PromptWorkExact:
		return p.PromptTokens == p.UpperBoundTokens && p.CalibrationID == ""
	case PromptWorkCalibrated:
		if p.CalibrationID == "" || len(p.CalibrationID) > 128 {
			return false
		}
		for _, c := range p.CalibrationID {
			if c < 33 || c > 126 {
				return false
			}
		}
		return true
	default:
		return false
	}
}

func promptWorkDigest(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, c := range value {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
