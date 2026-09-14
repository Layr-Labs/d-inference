package catalog

import (
	"fmt"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func validateRegisterModelRequest(req registerModelRequest) error {
	if err := req.HuggingFaceArtifact.Validate(); err != nil {
		return err
	}
	if strings.TrimSpace(req.ModelID) == "" {
		return fmt.Errorf("model_id is required")
	}
	if strings.TrimSpace(req.Version) == "" {
		return fmt.Errorf("version is required")
	}
	if !validRegistryIdentifier(req.ModelID, true) {
		return fmt.Errorf("model_id contains invalid characters or path components")
	}
	if !validRegistryIdentifier(req.Version, false) {
		return fmt.Errorf("version contains invalid characters or path components")
	}
	if strings.TrimSpace(req.Quantization) == "" {
		return fmt.Errorf("quantization is required")
	}
	if req.MaxContextLength <= 0 {
		return fmt.Errorf("max_context_length must be greater than zero")
	}
	if req.MaxOutputLength <= 0 {
		return fmt.Errorf("max_output_length must be greater than zero")
	}
	if req.MinRAMGB <= 0 {
		return fmt.Errorf("min_ram_gb must be greater than zero")
	}
	if req.InputPrice <= 0 {
		return fmt.Errorf("input_price is required and must be positive (micro-USD per 1M tokens)")
	}
	if req.OutputPrice <= 0 {
		return fmt.Errorf("output_price is required and must be positive (micro-USD per 1M tokens)")
	}
	if err := validateRequiredProviderCapabilities(
		req.ModelID, req.RequiredProviderCapabilities); err != nil {
		return err
	}
	return nil
}

func validateRequiredProviderCapabilities(modelID string, capabilities []string) error {
	seen := make(map[string]struct{}, len(capabilities))
	for _, capability := range capabilities {
		if capability == "" || capability != strings.TrimSpace(capability) {
			return fmt.Errorf("required_provider_capabilities contains a malformed capability name")
		}
		switch capability {
		case registry.ProviderCapabilityAppleM5, registry.ProviderCapabilityMLXNAX:
		default:
			return fmt.Errorf("required_provider_capabilities contains unknown capability %q", capability)
		}
		if _, duplicate := seen[capability]; duplicate {
			return fmt.Errorf("required_provider_capabilities contains duplicate capability %q", capability)
		}
		seen[capability] = struct{}{}
	}
	if modelID == registry.Qwen38NAXModelID {
		for _, required := range []string{
			registry.ProviderCapabilityAppleM5,
			registry.ProviderCapabilityMLXNAX,
		} {
			if _, ok := seen[required]; !ok {
				return fmt.Errorf(
					"model %q requires provider capability %q", modelID, required)
			}
		}
	}
	return nil
}

func validModelStatus(status string) bool {
	switch status {
	case "beta", "active", "deprecated", "retired":
		return true
	default:
		return false
	}
}
