package api

import (
	"fmt"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func isSystemOneDefinition(architecture string, capabilities []string) bool {
	return strings.EqualFold(strings.TrimSpace(architecture), "laya") &&
		len(capabilities) == 1 && capabilities[0] == "system_one"
}

func isSystemOneRegistryModel(rec *store.ModelRegistryRecord) bool {
	return rec != nil && isSystemOneDefinition(rec.Architecture, rec.Capabilities)
}

func isSystemOneRegistration(req registerModelRequest) bool {
	return isSystemOneDefinition(req.Architecture, req.Capabilities)
}

func (s *Server) rejectSystemOneGeneration(w http.ResponseWriter, model string) bool {
	if !s.registry.IsSystemOneModel(model) {
		return false
	}
	writeJSON(w, http.StatusUnprocessableEntity, errorResponse("model_capability",
		fmt.Sprintf("model %q evaluates decisions through /v1/systemone", model), withParam("model")))
	return true
}

func validateSystemOneDefinition(architecture string, capabilities []string) error {
	if strings.EqualFold(strings.TrimSpace(architecture), "laya") || contains(capabilities, "system_one") {
		if !isSystemOneDefinition(architecture, capabilities) {
			return fmt.Errorf("Laya requires architecture laya and exactly the system_one capability")
		}
	}
	return nil
}
