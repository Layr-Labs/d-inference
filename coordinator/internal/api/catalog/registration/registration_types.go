package registration

import (
	"github.com/eigeninference/d-inference/coordinator/api/modelprice"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const defaultModelRegistryCDNBaseURL = "https://models.darkbloom.ai"

type RegisterModelRequest struct {
	HuggingFaceArtifact          *store.HuggingFaceArtifact `json:"hugging_face_artifact,omitempty"`
	ModelID                      string                     `json:"model_id"`
	Version                      string                     `json:"version"`
	DisplayName                  string                     `json:"display_name"`
	Family                       string                     `json:"family"`
	Architecture                 string                     `json:"architecture"`
	Quantization                 string                     `json:"quantization"`
	MaxContextLength             int                        `json:"max_context_length"`
	MaxOutputLength              int                        `json:"max_output_length"`
	MinRAMGB                     int                        `json:"min_ram_gb"`
	Capabilities                 []string                   `json:"capabilities"`
	RequiredProviderCapabilities []string                   `json:"required_provider_capabilities"`
	Description                  string                     `json:"description"`
	RuntimeParameters            map[string]any             `json:"runtime_parameters"`
	Metadata                     map[string]any             `json:"metadata"`
	Promote                      bool                       `json:"promote"`
	// Platform price written at registration: input_price and output_price are
	// required; cache_read_price is optional (see modelprice.Input).
	modelprice.Input
}
