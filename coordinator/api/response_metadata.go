package api

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

const (
	metadataDetailsHeader = "X-Darkbloom-Metadata-Details"
	metadataDetailsField  = "metadata_details"
)

// committedProviderInfo is the consumer-safe provider snapshot taken at
// dispatch commit — the same values written to X-Provider-* headers.
type committedProviderInfo struct {
	ProviderID    string
	Attested      bool
	TrustLevel    registry.TrustLevel
	Encrypted     bool
	Chip          string
	MachineModel  string
	SecureEnclave *bool
	MDAVerified   bool
	SEPublicKey   string
}

func truthyRequestFlag(v any) bool {
	switch x := v.(type) {
	case bool:
		return x
	case string:
		switch strings.ToLower(strings.TrimSpace(x)) {
		case "true", "1", "yes":
			return true
		}
	case float64:
		return x != 0
	case json.Number:
		n, err := x.Int64()
		return err == nil && n != 0
	}
	return false
}

func metadataDetailsRequested(parsed map[string]any, header http.Header) bool {
	if header != nil && truthyRequestFlag(header.Get(metadataDetailsHeader)) {
		return true
	}
	if parsed != nil && truthyRequestFlag(parsed[metadataDetailsField]) {
		return true
	}
	return false
}

func stripMetadataDetailsFlag(parsed map[string]any) bool {
	if parsed == nil {
		return false
	}
	if _, ok := parsed[metadataDetailsField]; ok {
		delete(parsed, metadataDetailsField)
		return true
	}
	return false
}

// applyMetadataDetailsRequest consumes the coordinator-only metadata_details
// body flag (and/or X-Darkbloom-Metadata-Details header). The body field is
// stripped so it is never sealed into the provider payload. When the caller
// opted in, the header is set so dispatchOneProvider can stamp the pending
// request without threading another parameter. Returns whether parsed changed.
func applyMetadataDetailsRequest(r *http.Request, parsed map[string]any) bool {
	requested := false
	if r != nil {
		requested = metadataDetailsRequested(parsed, r.Header)
	} else {
		requested = metadataDetailsRequested(parsed, nil)
	}
	stripped := stripMetadataDetailsFlag(parsed)
	if requested && r != nil {
		if r.Header == nil {
			r.Header = make(http.Header)
		}
		r.Header.Set(metadataDetailsHeader, "true")
	}
	return stripped
}

func metadataDetailsFromRequest(r *http.Request) bool {
	if r == nil {
		return false
	}
	return metadataDetailsRequested(nil, r.Header)
}

func collectCommittedProviderInfo(provider *registry.Provider) committedProviderInfo {
	if provider == nil {
		return committedProviderInfo{}
	}
	provider.Mu().Lock()
	pubKey := provider.PublicKey
	attested := provider.Attested
	trustLevel := provider.TrustLevel
	attestResult := provider.AttestationResult
	mdaVerified := provider.MDAVerified
	provider.Mu().Unlock()

	info := committedProviderInfo{
		ProviderID:   provider.ID,
		Attested:     attested,
		TrustLevel:   trustLevel,
		Encrypted:    pubKey != "",
		Chip:         provider.Hardware.ChipName,
		MachineModel: provider.Hardware.MachineModel,
		MDAVerified:  mdaVerified,
	}
	if attestResult != nil {
		se := attestResult.SecureEnclaveAvailable
		info.SecureEnclave = &se
		info.SEPublicKey = attestResult.PublicKey
	}
	return info
}

func writeCommittedProviderHeaders(w http.ResponseWriter, info committedProviderInfo) {
	if info.Encrypted {
		w.Header().Set("X-Provider-Encrypted", "true")
	}
	if info.Attested {
		w.Header().Set("X-Provider-Attested", "true")
	} else {
		w.Header().Set("X-Provider-Attested", "false")
	}
	w.Header().Set("X-Provider-Trust-Level", string(info.TrustLevel))
	w.Header().Set("X-Provider-Id", info.ProviderID)
	w.Header().Set("X-Provider-Chip", info.Chip)
	w.Header().Set("X-Provider-Model", info.MachineModel)
	if info.SecureEnclave != nil {
		if *info.SecureEnclave {
			w.Header().Set("X-Provider-Secure-Enclave", "true")
		} else {
			w.Header().Set("X-Provider-Secure-Enclave", "false")
		}
	}
	if info.MDAVerified {
		w.Header().Set("X-Provider-Mda-Verified", "true")
	}
	if info.SEPublicKey != "" {
		w.Header().Set("X-Attestation-Se-Public-Key", info.SEPublicKey)
	}
}

func requestTimingDetails(timing *registry.RequestTiming) *types.RequestTimingDetails {
	if timing == nil {
		return nil
	}
	tj := &types.RequestTimingDetails{}
	if !timing.ParsedAt.IsZero() {
		tj.ParseUs = timing.ParsedAt.Sub(timing.ReceivedAt).Microseconds()
	}
	if !timing.ReservedAt.IsZero() && !timing.ParsedAt.IsZero() {
		tj.ReserveUs = timing.ReservedAt.Sub(timing.ParsedAt).Microseconds()
	}
	routeAnchor := timing.ReservedAt
	if !timing.MediaFetchedAt.IsZero() && !timing.ReservedAt.IsZero() {
		tj.MediaFetchUs = timing.MediaFetchedAt.Sub(timing.ReservedAt).Microseconds()
		routeAnchor = timing.MediaFetchedAt
	}
	if !timing.RoutedAt.IsZero() && !routeAnchor.IsZero() {
		tj.RouteUs = timing.RoutedAt.Sub(routeAnchor).Microseconds()
	}
	if !timing.QueuedAt.IsZero() && !timing.DispatchedAt.IsZero() {
		tj.QueueUs = timing.DispatchedAt.Sub(timing.QueuedAt).Microseconds()
	}
	if !timing.EncryptedAt.IsZero() && !timing.RoutedAt.IsZero() {
		tj.EncryptUs = timing.EncryptedAt.Sub(timing.RoutedAt).Microseconds()
	}
	if !timing.DispatchedAt.IsZero() && !timing.EncryptedAt.IsZero() {
		tj.DispatchUs = timing.DispatchedAt.Sub(timing.EncryptedAt).Microseconds()
	}
	if !timing.FirstChunkAt.IsZero() && !timing.DispatchedAt.IsZero() {
		tj.ProviderUs = timing.FirstChunkAt.Sub(timing.DispatchedAt).Microseconds()
	}
	return tj
}

func writeTimingHeader(w http.ResponseWriter, timing *registry.RequestTiming) {
	tj := requestTimingDetails(timing)
	if tj == nil {
		return
	}
	if tjJSON, err := json.Marshal(tj); err == nil {
		w.Header().Set("X-Timing", string(tjJSON))
	}
}

func buildChatCompletionMetadata(info committedProviderInfo, jobID string, timing *types.RequestTimingDetails) *types.ChatCompletionMetadata {
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
	}
}

func snapshotChatCompletionMetadata(pr *registry.PendingRequest, info committedProviderInfo) {
	if pr == nil || !pr.MetadataDetails || !isChatCompletionsConsumer(pr) {
		return
	}
	meta := buildChatCompletionMetadata(info, pr.RequestID, requestTimingDetails(pr.Timing))
	raw, err := json.Marshal(meta)
	if err != nil {
		return
	}
	pr.ResponseMetadata = raw
}

func hasChatCompletionMetadata(pr *registry.PendingRequest) bool {
	return pr != nil && pr.MetadataDetails && len(pr.ResponseMetadata) > 0
}

func attachChatCompletionMetadata(obj map[string]any, pr *registry.PendingRequest) {
	if obj == nil || !hasChatCompletionMetadata(pr) {
		return
	}
	obj["metadata"] = json.RawMessage(pr.ResponseMetadata)
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
	case completionsEndpoint, messagesEndpoint:
		return false
	}
	return true
}
