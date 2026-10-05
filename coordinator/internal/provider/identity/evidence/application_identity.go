package evidence

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func BinaryHash(provider *registry.Provider, seKey, registrationHash string) string {
	if registrationHash != "" {
		return registrationHash
	}
	if provider == nil || seKey == "" {
		return ""
	}

	provider.Mu().Lock()
	defer provider.Mu().Unlock()
	evidence := provider.ApplicationEvidence
	if evidence.EvidenceGeneration == 0 || evidence.SEPublicKey != seKey ||
		provider.PublicKey == "" || evidence.ProcessPublicKey != provider.PublicKey {
		return ""
	}
	return evidence.BinaryHash
}
