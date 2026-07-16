package api

import (
	"encoding/json"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestProviderInferenceWireMessageCarriesPreparedV2Attempt(t *testing.T) {
	pending := &registry.PendingRequest{
		CacheReceiptNonce:   "nonce",
		CacheScope:          "scope",
		PrefixCacheProtocol: 2,
	}
	encoded, err := json.Marshal(providerInferenceWireMessage(
		"request", "ephemeral", "ciphertext", pending))
	if err != nil {
		t.Fatal(err)
	}
	var decoded protocol.InferenceRequestMessage
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.RequestID != "request" ||
		decoded.EncryptedBody == nil ||
		decoded.EncryptedBody.EphemeralPublicKey != "ephemeral" ||
		decoded.EncryptedBody.Ciphertext != "ciphertext" ||
		decoded.CacheReceiptNonce != pending.CacheReceiptNonce ||
		decoded.CacheScope != pending.CacheScope ||
		decoded.PrefixCacheProtocol != 2 {
		t.Fatalf("decoded v2 wire request lost prepared attempt fields: %+v", decoded)
	}
}

func TestProviderInferenceWireMessageOmitsIncompleteCacheAttempt(t *testing.T) {
	message := providerInferenceWireMessage(
		"request", "ephemeral", "ciphertext",
		&registry.PendingRequest{
			CacheReceiptNonce:   "nonce",
			PrefixCacheProtocol: 2,
		})
	if message.CacheReceiptNonce != "" ||
		message.CacheScope != "" ||
		message.PrefixCacheProtocol != 0 {
		t.Fatalf("incomplete cache attempt leaked onto wire: %+v", message)
	}
}
