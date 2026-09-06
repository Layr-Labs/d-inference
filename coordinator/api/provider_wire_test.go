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
	_, _, pending := preparedCacheAttemptForTest(t)
	pending.FirstContentBudgetMS = 1800
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
		decoded.CacheReceiptNonce == "" ||
		decoded.CacheScope != pending.CachePlan.CacheScope ||
		decoded.PrefixCacheProtocol != 2 ||
		decoded.CacheReceiptBoundaryMode != protocol.PrefixCacheReadyBoundaryCheckpoint ||
		decoded.ToolSchemaMetadataProtocol != 1 {
		t.Fatalf("decoded v2 wire request lost prepared attempt fields: %+v", decoded)
	}
}

func TestProviderInferenceWireMessageOmitsUnpreparedCachePlan(t *testing.T) {
	message := providerInferenceWireMessage(
		"request", "ephemeral", "ciphertext",
		&registry.PendingRequest{
			FirstContentBudgetMS: 900,
			CachePlan:            registry.CachePlan{CacheScope: "unprepared-scope"},
		})
	if message.FirstContentBudgetMS != 900 ||
		message.CacheReceiptNonce != "" ||
		message.CacheScope != "" ||
		message.PrefixCacheProtocol != 0 ||
		message.CacheReceiptBoundaryMode != "" ||
		message.ToolSchemaMetadataProtocol != 1 {
		t.Fatalf("unprepared plan leaked onto wire: %+v", message)
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
	_, _, pending := preparedCacheAttemptForTest(t)
	pending.MaxTTFTMs, pending.FirstContentDeadline = 5000, deadline
	pending.Timing = &registry.RequestTiming{}
	scope := pending.CachePlan.CacheScope
	builder := providerInferenceFrameBuilder(
		"request", "ephemeral", "ciphertext", pending)

	// Later plan/deadline changes cannot alter the prepared immutable owner.
	// Actual Forget/reconfiguration revocation is covered separately.
	pending.FirstContentDeadline = time.Time{}
	pending.CachePlan = registry.CachePlan{CacheScope: "replacement-plan"}
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
	if decoded.CacheReceiptNonce == "" ||
		decoded.CacheScope != scope ||
		decoded.PrefixCacheProtocol != 2 ||
		decoded.CacheReceiptBoundaryMode != protocol.PrefixCacheReadyBoundaryCheckpoint {
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

func TestProviderInferenceQueuedCacheRevocationKeepsOrdinaryInference(t *testing.T) {
	for _, revoke := range []string{"reconfigure", "off", "forget", "terminal", "disconnect"} {
		t.Run(revoke, func(t *testing.T) {
			reg, provider, pending := preparedCacheAttemptForTest(t)
			deadline := time.Now().Add(time.Second)
			pending.FirstContentDeadline = deadline
			builder := providerInferenceFrameBuilder("request", "ephemeral", "ciphertext", pending)
			switch revoke {
			case "reconfigure":
				configureCachePreparationTest(t, reg)
			case "off":
				if err := reg.ConfigureCacheRouting(registry.CacheRoutingConfig{Mode: registry.CacheRoutingOff, ActivationPct: 100}); err != nil {
					t.Fatal(err)
				}
			case "forget":
				reg.ForgetCacheAttempt(pending)
			case "terminal":
				reg.MarkCacheAttemptTerminal(pending)
			case "disconnect":
				provider.AddPending(pending)
				reg.Disconnect(provider.ID)
			}
			encoded, err := builder(deadline.Add(-350 * time.Millisecond))
			if err != nil {
				t.Fatal(err)
			}
			var message protocol.InferenceRequestMessage
			if err := json.Unmarshal(encoded, &message); err != nil {
				t.Fatal(err)
			}
			if message.RequestID != "request" || message.EncryptedBody == nil || message.EncryptedBody.Ciphertext != "ciphertext" || message.EncryptedBody.EphemeralPublicKey != "ephemeral" || message.FirstContentBudgetMS != 350 {
				t.Fatalf("revocation changed ordinary encrypted request: %+v", message)
			}
			if message.CacheScope != "" || message.CacheReceiptNonce != "" || message.PrefixCacheProtocol != 0 || message.CacheReceiptBoundaryMode != "" {
				t.Fatalf("revoked cache fields emitted at dequeue: %+v", message)
			}
			if pending.CacheRoutingParticipates() {
				t.Fatal("never-dispatched cache scope still excludes ordinary calibration")
			}
			if _, err := builder(deadline); !errors.Is(err, errFirstContentDeadlineAtWriter) {
				t.Fatalf("revocation weakened deadline rejection: %v", err)
			}
		})
	}
}
