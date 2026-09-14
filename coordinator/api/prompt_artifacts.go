package api

import (
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
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

func (s *Server) SetPromptPreloadController(controller *promptcontract.PreloadController) {
	s.promptPreloader = controller
}

func (s *Server) PromptArtifactStatus(modelID string) (promptcontract.ProvisionStatus, bool) {
	if s.promptArtifacts == nil {
		return promptcontract.ProvisionStatus{}, false
	}
	return s.promptArtifacts.Status(modelID)
}

func (s *Server) reconcilePromptArtifacts(records []store.ModelRegistryRecord) error {
	if s.promptArtifacts == nil {
		return nil
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
	return s.promptArtifacts.Reconcile(manifests)
}
