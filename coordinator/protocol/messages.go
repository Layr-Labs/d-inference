package protocol

// Message type constants.
const (
	// Provider → Coordinator.
	TypeRegister               = "register"
	TypeHeartbeat              = "heartbeat"
	TypeInferenceAccepted      = "inference_accepted"
	TypeInferenceResponseChunk = "inference_response_chunk"
	TypeInferenceComplete      = "inference_complete"
	TypeInferenceError         = "inference_error"
	TypeAttestationResponse    = "attestation_response"
	// TypeCodeAttestationResponse is the provider's reply to the APNs-delivered
	// code-identity challenge (E_K(nonce) push). Distinct from the liveness
	// attestation_response: this is the WebSocket return leg of the push round-trip.
	TypeCodeAttestationResponse = "code_attestation_response"
	TypeLoadModelStatus         = "load_model_status"
	TypePrefetchModelStatus     = "prefetch_model_status"
	TypeModelsUpdate            = "models_update"
	TypePrefixCacheLookup       = "prefix_cache_lookup"
	TypePrefixCacheReady        = "prefix_cache_ready"
	TypePrefixCacheLookupV2     = "prefix_cache_lookup_v2"
	TypePrefixCacheReadyV2      = "prefix_cache_ready_v2"

	// TypeCapacityQuote is the provider's answer to a capacity_probe: an
	// admissibility verdict + calibrated TTFT estimate computed from its live
	// capacity snapshot. See CapacityQuoteMessage.
	TypeCapacityQuote = "capacity_quote"

	// Coordinator → Provider.
	TypeInferenceRequest               = "inference_request"
	TypeCancel                         = "cancel"
	TypeAttestationChallenge           = "attestation_challenge"
	TypeCodeAttestationResumeChallenge = "code_attestation_resume_challenge"
	TypeRuntimeStatus                  = "runtime_status"
	TypeLoadModel                      = "load_model"
	TypePrefetchModel                  = "prefetch_model"
	TypeDesiredModels                  = "desired_models"

	// TypeCapacityProbe asks a provider whether it could admit a request of a
	// given bucketed shape right now. Carries shape metadata only — never
	// prompt content or identity. See CapacityProbeMessage.
	TypeCapacityProbe = "capacity_probe"
	TypeTrustStatus   = "trust_status"
)
