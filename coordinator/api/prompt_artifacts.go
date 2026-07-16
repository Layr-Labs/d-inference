package api

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// SetPromptArtifactProvisioner attaches the optional Phase 1 optimizer
// lifecycle. Provisioning remains independent of inference availability.
func (s *Server) SetPromptArtifactProvisioner(provisioner *promptcontract.Provisioner) {
	s.promptArtifacts = provisioner
}

func (s *Server) SetPromptContractClient(client *promptcontract.Client) {
	s.promptContract = client
}

func (s *Server) PromptArtifactStatus(modelID string) (promptcontract.ProvisionStatus, bool) {
	if s.promptArtifacts == nil {
		return promptcontract.ProvisionStatus{}, false
	}
	return s.promptArtifacts.Status(modelID)
}

func (s *Server) reconcilePromptArtifacts(records []store.ModelRegistryRecord) {
	if s.promptArtifacts == nil {
		return
	}
	manifests := make([]promptcontract.Manifest, 0, len(records))
	for _, record := range records {
		if record.ActiveVersion == nil {
			continue
		}
		files := make([]promptcontract.Artifact, 0, len(record.Files))
		for _, file := range record.Files {
			files = append(files, promptcontract.Artifact{
				Path:      file.Path,
				Role:      file.Role,
				SizeBytes: file.SizeBytes,
				SHA256:    file.SHA256,
			})
		}
		manifests = append(manifests, promptcontract.Manifest{
			ModelID:         record.ID,
			R2Prefix:        record.ActiveVersion.R2Prefix,
			AggregateSHA256: record.ActiveVersion.AggregateSHA256,
			Files:           files,
		})
	}
	if err := s.promptArtifacts.Reconcile(manifests); err != nil {
		s.logger.Error("prompt artifact catalog reconcile rejected", "error", err)
	}
}

func (s *Server) planCacheRoute(
	ctx context.Context,
	account, model string,
	body []byte,
	hasMedia bool,
) registry.CachePlan {
	if s.promptArtifacts == nil || s.promptContract == nil {
		return registry.CachePlan{}
	}
	status, ok := s.promptArtifacts.Status(model)
	if !ok || !status.ArtifactReady || status.PromptContractID == "" {
		return registry.CachePlan{}
	}
	return s.registry.PlanCacheRoute(ctx, s.promptContract, registry.CachePlanInput{
		Account:          account,
		Model:            model,
		PromptContractID: status.PromptContractID,
		Body:             body,
		HasMedia:         hasMedia,
	})
}
