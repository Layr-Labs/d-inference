package registry

import "time"

// InferenceReceiptContext carries coordinator-owned request commitments through
// dispatch retries to the attempt that actually commits the response. It holds
// digests and identifiers only; prompt and output plaintext are never retained
// in registry state.
type InferenceReceiptContext struct {
	JobID                 string
	Nonce                 string
	CallerRef             string
	RequestSHA256         string
	RequestBytesSHA256    string
	ProviderRequestSHA256 string
	RequestedModel        string
	CreatedAt             time.Time
	LookupExpiresAt       time.Time
}
