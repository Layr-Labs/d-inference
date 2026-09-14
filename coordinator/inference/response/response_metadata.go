package response

import (
	"encoding/json"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

const (
	MetadataDetailsHeader       = "X-Darkbloom-Metadata-Details"
	metadataDetailsField        = "metadata_details"
	chatCompletionMetadataField = "metadata"
)

func buildChatCompletionMetadata(info ProviderInfo, jobID string, timing *types.RequestTimingDetails) *types.ChatCompletionMetadata {
	return &types.ChatCompletionMetadata{
		ProviderID:             info.ProviderID,
		ProviderAttested:       info.Attested,
		ProviderTrustLevel:     string(info.TrustLevel),
		ProviderEncrypted:      info.Encrypted,
		ProviderChip:           info.Chip,
		ProviderMachineModel:   info.MachineModel,
		ProviderSecureEnclave:  info.SecureEnclave,
		ProviderMDAVerified:    info.MDAVerified,
		AttestationSEPublicKey: info.SEPublicKey,
		JobID:                  jobID,
		Timing:                 timing,
		Location:               info.Location,
	}
}

func SnapshotChatCompletionMetadata(pr *registry.PendingRequest, info ProviderInfo) {
	if pr == nil || !pr.MetadataDetails || !isChatCompletionsConsumer(pr) {
		return
	}
	meta := buildChatCompletionMetadata(info, pr.RequestID, RequestTimingDetails(pr.Timing))
	raw, err := json.Marshal(meta)
	if err != nil {
		return
	}
	pr.ResponseMetadata = raw
}

func hasChatCompletionMetadata(pr *registry.PendingRequest) bool {
	return pr != nil && pr.MetadataDetails && len(pr.ResponseMetadata) > 0
}

func deleteChatCompletionMetadata(obj map[string]any) {
	for key := range obj {
		if strings.EqualFold(key, chatCompletionMetadataField) {
			delete(obj, key)
		}
	}
}

func attachChatCompletionMetadata(obj map[string]any, pr *registry.PendingRequest) {
	if obj == nil {
		return
	}
	// Provider output is untrusted. Reserve this top-level key even when the
	// caller opted out, then add only the coordinator-authored snapshot.
	deleteChatCompletionMetadata(obj)
	if !hasChatCompletionMetadata(pr) {
		return
	}
	obj[chatCompletionMetadataField] = json.RawMessage(pr.ResponseMetadata)
}

func chatCompletionMetadata(pr *registry.PendingRequest) *types.ChatCompletionMetadata {
	if !hasChatCompletionMetadata(pr) {
		return nil
	}
	var meta types.ChatCompletionMetadata
	if err := json.Unmarshal(pr.ResponseMetadata, &meta); err != nil {
		return nil
	}
	return &meta
}

func applyChatCompletionMetadataToResponse(resp *types.ChatCompletionResponse, pr *registry.PendingRequest) {
	if resp == nil {
		return
	}
	resp.Metadata = chatCompletionMetadata(pr)
}

func isChatCompletionsConsumer(pr *registry.PendingRequest) bool {
	if pr == nil || pr.IsResponsesAPI {
		return false
	}
	switch pr.ConsumerEndpoint {
	case CompletionsEndpoint, MessagesEndpoint:
		return false
	}
	return true
}
