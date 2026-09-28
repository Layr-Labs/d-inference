package protocol

// ProviderDrainMessage fences new dispatch and acknowledges all earlier frames
// on this connection, including inference terminal usage. IDs are random local
// barrier identifiers, never inference IDs or bearer credentials.
type ProviderDrainMessage struct {
	Type      string `json:"type"`
	RequestID string `json:"request_id"`
}
