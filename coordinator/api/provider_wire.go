package api

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func providerInferenceWireMessage(
	requestID, ephemeralPublicKey, ciphertext string,
	pr *registry.PendingRequest,
) protocol.InferenceRequestMessage {
	message := protocol.InferenceRequestMessage{
		Type:      protocol.TypeInferenceRequest,
		RequestID: requestID,
		EncryptedBody: &protocol.EncryptedPayload{
			EphemeralPublicKey: ephemeralPublicKey,
			Ciphertext:         ciphertext,
		},
	}
	if pr == nil || pr.CacheReceiptNonce == "" || pr.CacheScope == "" {
		return message
	}
	message.CacheReceiptNonce = pr.CacheReceiptNonce
	message.CacheScope = pr.CacheScope
	if pr.PrefixCacheProtocol > 0 {
		message.PrefixCacheProtocol = pr.PrefixCacheProtocol
	}
	return message
}
