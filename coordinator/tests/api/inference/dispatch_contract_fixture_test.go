package inference_test

// These independently pinned limits are observed through the real HTTP/WS
// dispatch path. A production limit change must update its contract explicitly.
const (
	maxCapacityClassRetries            = 3
	maxDispatchAttempts                = 64
	maxHeldBoilerplate                 = 8
	predictiveRefusalRefreshThreshold  = 2
	rejectionReasonOversized           = "oversized_request"
	rejectionReasonDeadlineUnreachable = "deadline_unreachable"
)
