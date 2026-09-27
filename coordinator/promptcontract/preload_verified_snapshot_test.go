package promptcontract

import (
	"strings"
	"testing"
	"unsafe"
)

func TestProvisionerVerifiedPreloadSnapshotIsCoherentDetachedAndFull(t *testing.T) {
	backing := strings.Repeat("a", 1<<20)
	model, hash := backing[100:110], backing[200:264]
	p := &Provisioner{generation: 37, statuses: map[string]ProvisionStatus{
		model:     {ArtifactReady: true, PromptContractID: hash, ModelAggregateSHA256: hash, Path: "/private/fixture"},
		"other":   {ArtifactReady: true, PromptContractID: hash, ModelAggregateSHA256: strings.Repeat("b", 64)},
		"pending": {PromptContractID: strings.Repeat("c", 64)},
		"failed":  {LastError: "synthetic failure"},
	}}
	snapshot, artifacts := p.VerifiedPreloadArtifacts()
	if snapshot.Generation != 37 || snapshot.Counts != (ProvisionCounts{Ready: 2, Pending: 1, Failed: 1}) ||
		len(snapshot.ContractIDs) != 1 || len(artifacts) != 2 {
		t.Fatal("verified tuple snapshot pruned shared-contract models or mixed counts/generation")
	}
	first := artifacts[0]
	if first.CatalogGeneration != 37 || first.ModelID != model || first.ModelAggregateSHA256 != hash || first.PromptContractID != hash {
		t.Fatal("snapshot identity differs from the verified catalog")
	}
	if unsafe.StringData(first.ModelID) == unsafe.StringData(model) || unsafe.StringData(first.ModelAggregateSHA256) == unsafe.StringData(hash) ||
		unsafe.StringData(first.PromptContractID) == unsafe.StringData(hash) || unsafe.StringData(snapshot.ContractIDs[0]) == unsafe.StringData(hash) {
		t.Fatal("snapshot retained source backing storage")
	}
	artifacts[0].ModelID, snapshot.ContractIDs[0] = "changed", "changed"
	current, again := p.VerifiedPreloadArtifacts()
	if current.ContractIDs[0] != hash || again[0].ModelID != model {
		t.Fatal("caller mutated authoritative membership")
	}
	p.mu.Lock()
	p.closed = true
	p.mu.Unlock()
	if closed, values := p.VerifiedPreloadArtifacts(); closed.Generation != 0 || len(values) != 0 {
		t.Fatal("closed provisioner retained selection authority")
	}
}
