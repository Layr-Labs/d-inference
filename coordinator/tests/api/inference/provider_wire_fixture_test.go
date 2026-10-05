package inference_test

import (
	"encoding/json"
	"time"

	providerwire "github.com/eigeninference/d-inference/coordinator/internal/inference/providerwire"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func providerInferenceWireMessage(
	requestID, ephemeralPublicKey, ciphertext string,
	pr *registry.PendingRequest,
) protocol.InferenceRequestMessage {
	data, err := providerwire.FrameBuilder(requestID, ephemeralPublicKey, ciphertext, pr)(time.Time{})
	if err != nil {
		panic(err)
	}
	var message protocol.InferenceRequestMessage
	if err := json.Unmarshal(data, &message); err != nil {
		panic(err)
	}
	return message
}
