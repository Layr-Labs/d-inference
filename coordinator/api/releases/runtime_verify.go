package releases

import (
	"strings"

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

	return scoped.verifyReportedHashes(scopedReportedTemplates)
}

func (manifest *RuntimeManifest) verifyReportedHashes(templateHashes map[string]string) (bool, []protocol.RuntimeMismatch) {
	if manifest == nil {
		return true, nil
	}

	var mismatches []protocol.RuntimeMismatch

	if len(manifest.TemplateHashes) > 0 {
		// Each template name maps to the SET of hashes accepted across every
		// active release; the reported value must be one of them.
		for name, accepted := range manifest.TemplateHashes {
			if len(accepted) == 0 {
				continue
			}
			expected := "one of " + strings.Join(sortedTemplateHashes(accepted), ",")
			got, ok := templateHashes[name]
			if !ok || strings.TrimSpace(got) == "" {
				mismatches = append(mismatches, protocol.RuntimeMismatch{
					Component: "template:" + name,
					Expected:  expected,
					Got:       "(missing)",
				})
				continue
			}
			if !templateHashAccepted(accepted, got) {
				mismatches = append(mismatches, protocol.RuntimeMismatch{
					Component: "template:" + name,
					Expected:  expected,
					Got:       got,
				})
			}
		}
		for name, got := range templateHashes {
			if len(manifest.TemplateHashes[name]) == 0 {
				mismatches = append(mismatches, protocol.RuntimeMismatch{
					Component: "template:" + name,
					Expected:  "template listed in runtime manifest",
					Got:       got,
				})
			}
		}
	}

	return len(mismatches) == 0, mismatches
}
