package registry_test

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
)

// Synthetic arithmetic evidence, never a hardware measurement or promotion.
func syntheticServingProfile() *performance.Profile {
	return &performance.Profile{
		ID: "test-only-ultra", ModelID: "model", ArtifactSHA256: strings.Repeat("a", 64),
		ProviderVersion: "test", RuntimeRevision: performance.RuntimeRevision,
		KVBackend: "paged", ChipName: "Apple M5 Ultra", GPUCores: 80, MemoryGB: 192,
		ContextTokensMax: 32768, MaxConcurrency: 16, WholeMacConcurrency: 16,
		QualificationReportSHA256: strings.Repeat("b", 64),
		BatchCurve: []performance.BatchPoint{
			{Width: 1, DecodeP10TPS: 90, AggregateDecodeTPS: 100, PrefillTPS: 6000, FirstContentP95MS: 1200},
			{Width: 16, DecodeP10TPS: 35, AggregateDecodeTPS: 700, PrefillTPS: 6000, FirstContentP95MS: 2800},
		},
	}
}
