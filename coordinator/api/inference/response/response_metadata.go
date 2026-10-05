package response

import (
	"encoding/json"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/geo"
	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	sse "github.com/eigeninference/d-inference/coordinator/internal/inference/sse"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// committedProviderInfo is the consumer-safe provider snapshot taken at
// dispatch commit — the same values written to X-Provider-* headers.
type CommittedProviderInfo struct {
	Verification  *registry.Verification
	ProviderID    string
	Attested      bool
	TrustLevel    registry.TrustLevel
	Encrypted     bool
	Chip          string
	MachineModel  string
	SecureEnclave *bool
	MDAVerified   bool
	SEPublicKey   string
	Location      *types.ProviderApproxLocation
}

func CollectCommittedProviderInfo(provider *registry.Provider) CommittedProviderInfo {
	if provider == nil {
		return CommittedProviderInfo{}
	}
	provider.Mu().Lock()
	pubKey := provider.PublicKey
	attested := provider.Attested
	trustLevel := provider.TrustLevel
	attestResult := provider.AttestationResult
	mdaVerified := provider.MDAVerified
	var locCopy *store.ProviderLocation
	if provider.Location != nil {
		cp := *provider.Location
		locCopy = &cp
	}
	provider.Mu().Unlock()

	info := CommittedProviderInfo{
		ProviderID:   provider.ID,
		Attested:     attested,
		TrustLevel:   trustLevel,
		Encrypted:    pubKey != "",
		Chip:         provider.Hardware.ChipName,
		MachineModel: provider.Hardware.MachineModel,
		MDAVerified:  mdaVerified,
		Location:     geo.ConsumerSafeLocation(locCopy),
	}
	if attestResult != nil {
		se := attestResult.SecureEnclaveAvailable
		info.SecureEnclave = &se
		info.SEPublicKey = attestResult.PublicKey
	}
	return info
}

func WriteCommittedProviderHeaders(w http.ResponseWriter, info CommittedProviderInfo) {
	if info.Verification != nil {
		raw, _ := json.Marshal(info.Verification)
		w.Header().Set("X-Provider-Verification", string(raw))
		w.Header().Set("X-Provider-Authorization-Method", info.Verification.Method())
	}
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

func RequestTimingDetails(timing *registry.RequestTiming) *types.RequestTimingDetails {
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

func buildChatCompletionMetadata(info CommittedProviderInfo, jobID string, timing *types.RequestTimingDetails) *types.ChatCompletionMetadata {
	return &types.ChatCompletionMetadata{
		Verification:           info.Verification,
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

func SnapshotChatCompletionMetadata(pr *registry.PendingRequest, info CommittedProviderInfo) {
	if pr == nil || !pr.MetadataDetails || !IsChatCompletionsConsumer(pr) {
		return
	}
	meta := buildChatCompletionMetadata(info, pr.RequestID, RequestTimingDetails(pr.Timing))
	raw, err := json.Marshal(meta)
	if err != nil {
		return
	}
	pr.ResponseMetadata = raw
}

func HasChatCompletionMetadata(pr *registry.PendingRequest) bool {
	return pr != nil && pr.MetadataDetails && len(pr.ResponseMetadata) > 0
}

func AttachChatCompletionMetadata(obj map[string]any, pr *registry.PendingRequest) {
	if obj == nil {
		return
	}
	// Provider output is untrusted. Reserve this top-level key even when the
	// caller opted out, then add only the coordinator-authored snapshot.
	sse.DeleteChatCompletionMetadata(obj)
	if !HasChatCompletionMetadata(pr) {
		return
	}
	obj[sse.ChatCompletionMetadataField] = json.RawMessage(pr.ResponseMetadata)
}

func chatCompletionMetadata(pr *registry.PendingRequest) *types.ChatCompletionMetadata {
	if !HasChatCompletionMetadata(pr) {
		return nil
	}
	var meta types.ChatCompletionMetadata
	if err := json.Unmarshal(pr.ResponseMetadata, &meta); err != nil {
		return nil
	}
	return &meta
}

func ApplyChatCompletionMetadataToResponse(resp *types.ChatCompletionResponse, pr *registry.PendingRequest) {
	if resp == nil {
		return
	}
	resp.Metadata = chatCompletionMetadata(pr)
}

func IsChatCompletionsConsumer(pr *registry.PendingRequest) bool {
	if pr == nil || pr.IsResponsesAPI {
		return false
	}
	switch pr.ConsumerEndpoint {
	case inreq.CompletionsEndpoint, inreq.MessagesEndpoint:
		return false
	}
	return true
}
