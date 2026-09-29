package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestPromptWorkQualificationRequiresIdentityAndExplicitBounds(t *testing.T) {
	base := PromptWork{Version: 1, Source: PromptWorkExact, PromptTokens: 8828, UpperBoundTokens: 8828, ModelArtifactHash: strings.Repeat("a", 64), PromptContractID: strings.Repeat("b", 64)}
	for name, mutate := range map[string]func(*PromptWork){
		"unknown_version":         func(p *PromptWork) { p.Version = 2 },
		"unknown_source":          func(p *PromptWork) { p.Source = "future" },
		"no_bound":                func(p *PromptWork) { p.UpperBoundTokens = 0 },
		"exact_uncertainty":       func(p *PromptWork) { p.UpperBoundTokens++ },
		"artifact_revision":       func(p *PromptWork) { p.ModelArtifactHash = strings.Repeat("c", 64) },
		"template_revision":       func(p *PromptWork) { p.PromptContractID = strings.Repeat("d", 64) },
		"oversized":               func(p *PromptWork) { p.PromptTokens = MaxPromptWorkTokens + 1; p.UpperBoundTokens = p.PromptTokens },
		"unqualified_calibration": func(p *PromptWork) { p.Source = PromptWorkCalibrated },
	} {
		t.Run(name, func(t *testing.T) {
			p := base
			mutate(&p)
			if p.IsQualifiedFor(base.ModelArtifactHash, base.PromptContractID) {
				t.Fatal("invalid evidence qualified")
			}
		})
	}
	encoded, err := json.Marshal(InferenceRequestMessage{Type: TypeInferenceRequest, PromptWork: &base})
	if err != nil {
		t.Fatal(err)
	}
	var decoded InferenceRequestMessage
	if err = json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.PromptWork == nil || *decoded.PromptWork != base {
		t.Fatal("wire lost provenance")
	}
	base.Source = PromptWorkCalibrated
	base.CalibrationID = "reviewed-corpus-v1"
	base.UpperBoundTokens = 10000
	if !base.IsQualifiedFor(base.ModelArtifactHash, base.PromptContractID) {
		t.Fatal("valid calibrated uncertainty rejected")
	}
}
