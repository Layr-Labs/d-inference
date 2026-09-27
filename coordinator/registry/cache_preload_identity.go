package registry

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

// CachePreloadIdentities is a read-only exact catalog/allowlist projection. It
// never computes account scope, samples, debits QPS or observes demand. These
// identities permit optional tokenizer selection, not inference authorization.
func (r *Registry) CachePreloadIdentities(verified []promptcontract.VerifiedPreloadArtifact) []promptcontract.PreloadDemandIdentity {
	if r == nil || len(verified) > maxCacheArtifacts {
		return nil
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	var admitted []promptcontract.PreloadDemandIdentity
	for _, identity := range verified {
		if identity.CatalogGeneration == 0 || identity.ModelID == "" || len(identity.ModelID) > 512 ||
			strings.TrimSpace(identity.ModelID) != identity.ModelID || strings.ContainsAny(identity.ModelID, "\x00\r\n\t*") ||
			!validLowerHex256(identity.ModelAggregateSHA256) || !validLowerHex256(identity.PromptContractID) {
			continue
		}
		input := CachePlanInput{Model: identity.ModelID, ModelAggregateSHA256: identity.ModelAggregateSHA256,
			PromptContractID: identity.PromptContractID}
		if cachePlanAuthorityRejection(r.cachePlanAuthorityLocked(identity.ModelID, false), input) != "" {
			continue
		}
		identity.ModelID = strings.Clone(identity.ModelID)
		identity.ModelAggregateSHA256 = strings.Clone(identity.ModelAggregateSHA256)
		identity.PromptContractID = strings.Clone(identity.PromptContractID)
		admitted = append(admitted, identity)
	}
	return admitted
}
