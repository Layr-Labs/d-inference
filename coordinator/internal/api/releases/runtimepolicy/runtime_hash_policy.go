package runtimepolicy

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func Verify(acceptedByName map[string]map[string]bool, templateHashes map[string]string) (bool, []protocol.RuntimeMismatch) {
	var mismatches []protocol.RuntimeMismatch

	if len(acceptedByName) > 0 {
		// Each template name maps to the SET of hashes accepted across every
		// active release; the reported value must be one of them.
		for name, accepted := range acceptedByName {
			if len(accepted) == 0 {
				continue
			}
			expected := "one of " + strings.Join(SortedTemplateHashes(accepted), ",")
			got, ok := templateHashes[name]
			if !ok || strings.TrimSpace(got) == "" {
				mismatches = append(mismatches, protocol.RuntimeMismatch{
					Component: "template:" + name,
					Expected:  expected,
					Got:       "(missing)",
				})
				continue
			}
			if !TemplateHashAccepted(accepted, got) {
				mismatches = append(mismatches, protocol.RuntimeMismatch{
					Component: "template:" + name,
					Expected:  expected,
					Got:       got,
				})
			}
		}
		for name, got := range templateHashes {
			if len(acceptedByName[name]) == 0 {
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
