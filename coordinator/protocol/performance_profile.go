package protocol

// ServingPerformanceProfileReference names coordinator-owned reviewed release
// data. Provider telemetry cannot certify its own width or degradation curve.
type ServingPerformanceProfileReference struct {
	ID              string              `json:"id"`
	RuntimeRevision string              `json:"runtime_revision"`
	ContextTokens   int                 `json:"context_tokens"`
	MTP             *ServingMTPIdentity `json:"mtp,omitempty"`
}

// ServingMTPIdentity names the actual verified assistant and effective decode
// configuration. Omission means plain target execution, never unknown MTP.
type ServingMTPIdentity struct {
	Enabled                       bool   `json:"enabled"`
	ArtifactSHA256                string `json:"artifact_sha256"`
	MaxDraftTokens                int    `json:"max_draft_tokens"`
	FixedDraftTokens              *int   `json:"fixed_draft_tokens,omitempty"`
	MaxSpeculativeBatch           int    `json:"max_speculative_batch"`
	VerificationMode              string `json:"verification_mode"`
	MaxAutomaticRectangularTokens int    `json:"max_automatic_rectangular_tokens"`
}

func (m *ServingMTPIdentity) Equal(other *ServingMTPIdentity) bool {
	if m == nil || other == nil {
		return m == nil && other == nil
	}
	if (m.FixedDraftTokens == nil) != (other.FixedDraftTokens == nil) ||
		(m.FixedDraftTokens != nil && *m.FixedDraftTokens != *other.FixedDraftTokens) {
		return false
	}
	return m.Enabled == other.Enabled && m.ArtifactSHA256 == other.ArtifactSHA256 &&
		m.MaxDraftTokens == other.MaxDraftTokens && m.MaxSpeculativeBatch == other.MaxSpeculativeBatch &&
		m.VerificationMode == other.VerificationMode && m.MaxAutomaticRectangularTokens == other.MaxAutomaticRectangularTokens
}

func (m *ServingMTPIdentity) Clone() *ServingMTPIdentity {
	if m == nil {
		return nil
	}
	out := *m
	out.FixedDraftTokens = clonePtr(m.FixedDraftTokens)
	return &out
}
