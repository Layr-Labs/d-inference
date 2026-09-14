package dispatchplan

import (
	"crypto/rand"
	"encoding/hex"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// bucketPromptTokens rounds a prompt-token estimate UP to the probe bucket
// granularity (privacy invariant: probes carry shape, never exact counts).
func bucketPromptTokens(tokens int) int {
	if tokens <= 0 {
		return 0
	}
	const bucket = protocol.CapacityProbePromptBucketTokens
	return (tokens + bucket - 1) / bucket * bucket
}

// newQuoteID mints the random, request-local probe correlation ID. 128 bits —
// deliberately NOT the public request ID, so a probed provider can never link
// a probe to a request it later serves.
func newQuoteID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}
