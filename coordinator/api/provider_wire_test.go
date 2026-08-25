package api

import (
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestProviderInferenceWireMessageCarriesPreparedV2Attempt(t *testing.T) {
	pending := &registry.PendingRequest{
		FirstContentBudgetMS: 1800,
		CacheReceiptNonce:    "nonce",
		CacheScope:           "scope",
		PrefixCacheProtocol:  2,
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
		decoded.FirstContentBudgetMS != pending.FirstContentBudgetMS ||
		decoded.CacheReceiptNonce != pending.CacheReceiptNonce ||
		decoded.CacheScope != pending.CacheScope ||
		decoded.PrefixCacheProtocol != 2 ||
		decoded.ToolSchemaMetadataProtocol != 1 {
		t.Fatalf("decoded v2 wire request lost prepared attempt fields: %+v", decoded)
	}
}

func TestProviderInferenceWireMessageOmitsIncompleteCacheAttempt(t *testing.T) {
	message := providerInferenceWireMessage(
		"request", "ephemeral", "ciphertext",
		&registry.PendingRequest{
			FirstContentBudgetMS: 900,
			CacheReceiptNonce:    "nonce",
			PrefixCacheProtocol:  2,
		})
	if message.FirstContentBudgetMS != 900 ||
		message.CacheReceiptNonce != "" ||
		message.CacheScope != "" ||
		message.PrefixCacheProtocol != 0 ||
		message.ToolSchemaMetadataProtocol != 1 {
		t.Fatalf("incomplete cache attempt leaked onto wire: %+v", message)
	}
}

func TestProviderInferenceWireMessageOmitsNonPositiveFirstContentBudget(t *testing.T) {
	for _, budgetMS := range []int64{0, -1} {
		message := providerInferenceWireMessage(
			"request", "ephemeral", "ciphertext",
			&registry.PendingRequest{FirstContentBudgetMS: budgetMS})
		if message.FirstContentBudgetMS != 0 {
			t.Fatalf("budget %d leaked onto wire: %+v", budgetMS, message)
		}
	}
}

func TestProviderInferenceFrameBuilderRefreshesBudgetAtDequeue(t *testing.T) {
	deadline := time.Now().Add(500 * time.Millisecond)
	pending := &registry.PendingRequest{
		MaxTTFTMs:            5_000,
		FirstContentDeadline: deadline,
		CacheReceiptNonce:    "original-nonce",
		CacheScope:           "original-scope",
		PrefixCacheProtocol:  2,
		Timing:               &registry.RequestTiming{},
	}
	builder := providerInferenceFrameBuilder(
		"request", "ephemeral", "ciphertext", pending)

	// Simulate dispatch cleanup after the immutable frame snapshot is handed to
	// the writer. The writer must neither read nor mutate PendingRequest.
	pending.FirstContentDeadline = time.Time{}
	pending.CacheReceiptNonce = ""
	pending.CacheScope = ""
	pending.PrefixCacheProtocol = 0
	dequeuedAt := deadline.Add(-420 * time.Millisecond)
	encoded, err := builder(dequeuedAt)
	if err != nil {
		t.Fatalf("builder: %v", err)
	}
	var decoded protocol.InferenceRequestMessage
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.FirstContentBudgetMS != 420 {
		t.Fatalf("dequeue budget = %dms, want 420ms", decoded.FirstContentBudgetMS)
	}
	if decoded.CacheReceiptNonce != "original-nonce" ||
		decoded.CacheScope != "original-scope" ||
		decoded.PrefixCacheProtocol != 2 {
		t.Fatalf("builder did not use immutable cache snapshot: %+v", decoded)
	}
	if pending.MaxTTFTMs != 5_000 {
		t.Fatalf("builder mutated MaxTTFTMs to %.1f", pending.MaxTTFTMs)
	}
	if !pending.Timing.DispatchedAt.IsZero() {
		t.Fatalf("builder mutated DispatchedAt to %v", pending.Timing.DispatchedAt)
	}
}

func TestProviderInferenceFrameBuilderRejectsExpiredDeadline(t *testing.T) {
	builder := providerInferenceFrameBuilder(
		"request", "ephemeral", "ciphertext",
		&registry.PendingRequest{
			FirstContentDeadline: time.Now().Add(-time.Millisecond),
		},
	)
	if _, err := builder(time.Now()); !errors.Is(err, errFirstContentDeadlineAtWriter) {
		t.Fatalf("expired builder error = %v, want deadline sentinel", err)
	}
}
