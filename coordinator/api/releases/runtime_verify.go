package releases

import (
	runtimepolicy "github.com/eigeninference/d-inference/coordinator/internal/api/releases/runtimepolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// SetRuntimeManifest configures the known-good runtime manifest for provider
// verification. Pass nil to disable runtime verification (all providers pass).
func (s *Owner) SetRuntimeManifest(m *RuntimeManifest) {
	if m != nil {
		m = m.clone()
	}
	s.runtimeManifest.Store(m)
}

func (s *Owner) VerifyRuntimeHashesForBackend(backend string, templateHashes map[string]string) (bool, []protocol.RuntimeMismatch) {
	return s.runtimeManifest.Load().verifyForBackend(backend, templateHashes)
}

func (manifest *RuntimeManifest) verifyForBackend(backend string, templateHashes map[string]string) (bool, []protocol.RuntimeMismatch) {
	if manifest == nil {
		return true, nil
	}

	// Only the Swift (mlx-swift) backend is supported; any other backend is
	// rejected outright.
	if !registry.BackendUsesSwiftRuntime(backend) {
		return false, []protocol.RuntimeMismatch{{
			Component: "backend",
			Expected:  "mlx-swift",
			Got:       backend,
		}}
	}

	scoped := NewRuntimeManifest()
	scopedReportedTemplates := make(map[string]string)

	if accepted := manifest.TemplateHashes["mlx_metallib"]; len(accepted) > 0 {
		scoped.TemplateHashes["mlx_metallib"] = accepted
	}
	if got := templateHashes["mlx_metallib"]; got != "" {
		scopedReportedTemplates["mlx_metallib"] = got
	}

	return runtimepolicy.Verify(scoped.TemplateHashes, scopedReportedTemplates)
}
