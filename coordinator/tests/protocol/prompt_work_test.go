package protocol_test

import (
	"encoding/json"
	"strings"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestPromptWorkQualificationRequiresIdentityAndExplicitBounds(t *testing.T) {
	base := production.PromptWork{Version: 1, Source: production.PromptWorkExact, PromptTokens: 8828, UpperBoundTokens: 8828, ModelArtifactHash: strings.Repeat("a", 64), PromptContractID: strings.Repeat("b", 64)}
	for name, mutate := range map[string]func(*production.PromptWork){
		"unknown_version":   func(p *production.PromptWork) { p.Version = 2 },
		"unknown_source":    func(p *production.PromptWork) { p.Source = "future" },
		"no_bound":          func(p *production.PromptWork) { p.UpperBoundTokens = 0 },
		"exact_uncertainty": func(p *production.PromptWork) { p.UpperBoundTokens++ },
		"artifact_revision": func(p *production.PromptWork) { p.ModelArtifactHash = strings.Repeat("c", 64) },
		"template_revision": func(p *production.PromptWork) { p.PromptContractID = strings.Repeat("d", 64) },
		"oversized": func(p *production.PromptWork) {
			p.PromptTokens = production.MaxPromptWorkTokens + 1
			p.UpperBoundTokens = p.PromptTokens
		},
		"unqualified_calibration": func(p *production.PromptWork) { p.Source = production.PromptWorkCalibrated },
	} {
		t.Run(name, func(t *testing.T) {
			p := base
			mutate(&p)
			if p.IsQualifiedFor(base.ModelArtifactHash, base.PromptContractID) {
				t.Fatal("invalid evidence qualified")
			}
		})
	}
	encoded, err := json.Marshal(production.InferenceRequestMessage{Type: production.TypeInferenceRequest, PromptWork: &base})
	if err != nil {
		t.Fatal(err)
	}
	var decoded production.InferenceRequestMessage
	if err = json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.PromptWork == nil || *decoded.PromptWork != base {
		t.Fatal("wire lost provenance")
	}
	base.Source = production.PromptWorkCalibrated
	base.CalibrationID = "reviewed-corpus-v1"
	base.UpperBoundTokens = 10000
	if !base.IsQualifiedFor(base.ModelArtifactHash, base.PromptContractID) {
		t.Fatal("valid calibrated uncertainty rejected")
	}
}
