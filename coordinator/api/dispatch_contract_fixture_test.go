package api

// Independent wire, metric and policy expectations used by real HTTP/provider
// fixtures. Keep production policy in inference/dispatch; these values are
// assertions against that contract, not a second production configuration.
const (
	deadlineBucketUnderHalf            = "under_half"
	deadlineBucketMid                  = "mid"
	deadlineBucketNearDeadline         = "near_deadline"
	deadlineBucketOver                 = "over"
	metricRouteLatency                 = "routing.route_latency_ms"
	envQueueBeforeShed                 = "EIGENINFERENCE_QUEUE_BEFORE_SHED"
	envColdDispatch                    = "EIGENINFERENCE_COLD_DISPATCH"
	chunkBufferSize                    = 256
	maxDispatchAttempts                = 64
	maxCapacityClassRetries            = 3
	maxFirstChunkTimeoutRetries        = 3
	maxHeldBoilerplate                 = 8
	errFirstContentDeadlineExpired     = "first-content deadline expired before provider dispatch"
	envTTFTTerminalReject              = "EIGENINFERENCE_TTFT_TERMINAL_REJECT"
	rejectionReasonOversized           = "oversized_request"
	errQueueDeadlineExpired            = "first-content deadline expired while queued for a provider"
	rejectionReasonDeadlineUnreachable = "deadline_unreachable"
	kvBackendTagKey                    = "kv_backend:"
	kvBackendFallbackTagKey            = "kv_backend_fallback:"
	orClassProvider5xx                 = "provider_5xx"
	orClassTimeout                     = "timeout"
	orClassRateLimited                 = "rate_limited"
	orClassClientError                 = "client_error"
	phaseBeforeFirstToken              = "before_first_token"
	legacyCacheBustField               = "prompt_cache_key"
)
