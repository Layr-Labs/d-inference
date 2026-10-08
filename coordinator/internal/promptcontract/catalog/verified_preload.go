package catalog

import (
	"sort"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/identity"
)

// Internal-use artifact identity, not an authorization or wire message.
type VerifiedPreloadArtifact struct {
	CatalogGeneration    uint64
	ModelID              string
	ModelAggregateSHA256 string
	PromptContractID     string
}

// VerifiedPreloadArtifacts is an internal-use, coherent handoff. Full verified
// membership remains authoritative; selection never prunes the catalog. Values
// are detached and omit paths, URLs, errors and all request/account state.
func (p *State) VerifiedPreloadArtifacts() (Snapshot, []VerifiedPreloadArtifact) {
	if p == nil {
		return Snapshot{}, nil
	}
	p.mu.RLock()
	defer p.mu.RUnlock()
	snapshot := p.snapshotLocked()
	for i, id := range snapshot.ContractIDs {
		snapshot.ContractIDs[i] = strings.Clone(id)
	}
	artifacts := make([]VerifiedPreloadArtifact, 0, snapshot.Counts.Ready)
	for modelID, status := range p.statuses {
		if !status.ArtifactReady {
			continue
		}
		if _, err := identity.ParseDigest(status.PromptContractID); err == nil {
			artifacts = append(artifacts, VerifiedPreloadArtifact{
				CatalogGeneration: snapshot.Generation, ModelID: strings.Clone(modelID),
				ModelAggregateSHA256: strings.Clone(status.ModelAggregateSHA256),
				PromptContractID:     strings.Clone(status.PromptContractID),
			})
		}
	}
	sort.Slice(artifacts, func(i, j int) bool { return artifacts[i].ModelID < artifacts[j].ModelID })
	return snapshot, artifacts
}
