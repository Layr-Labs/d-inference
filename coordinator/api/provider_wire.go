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
		Type:                       protocol.TypeInferenceRequest,
		RequestID:                  requestID,
		ToolSchemaMetadataProtocol: 1,
		EncryptedBody: &protocol.EncryptedPayload{
			EphemeralPublicKey: ephemeralPublicKey,
			Ciphertext:         ciphertext,
		},
	}
	if pr == nil || pr.CacheScope == "" {
		return message
	}
	message.CacheScope = pr.CacheScope
	if pr.CacheReceiptNonce == "" {
		return message
	}
	message.CacheReceiptNonce = pr.CacheReceiptNonce
	if pr.PrefixCacheProtocol > 0 {
		message.PrefixCacheProtocol = pr.PrefixCacheProtocol
	}
	return message
}
