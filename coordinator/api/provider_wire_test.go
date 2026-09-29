package api

import (
	"encoding/json"
	"errors"
	"strings"
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
	// A first plan is novel fleet-wide: the field must still be present as 0 so
	// the provider can tell it from an older coordinator that omits it.
	if decoded.CacheRepeatedPrefixTokens == nil || *decoded.CacheRepeatedPrefixTokens != 0 {
		t.Fatalf("novel plan repeat demand=%v on wire, want 0", decoded.CacheRepeatedPrefixTokens)
	}
	if !strings.Contains(string(encoded), `"cache_repeated_prefix_tokens":0`) {
		t.Fatalf("0 repeat demand omitted from wire JSON: %s", encoded)
	}
}

func TestProviderInferenceFrameFreezesCommittedServiceReservation(t *testing.T) {
	_, provider, pending := preparedCacheAttemptForTest(t)
	provider.AddPending(pending)
	firstID := pending.ServiceReservationID()
	if firstID == "" || firstID == pending.RequestID {
		t.Fatal("committed attempt lacks an independent service reservation")
	}
	builder := providerInferenceFrameBuilder("request", "ephemeral", "ciphertext", pending)
	provider.RemovePending(pending.RequestID)
	provider.AddPending(pending)
	t.Cleanup(func() { provider.RemovePending(pending.RequestID) })
	if pending.ServiceReservationID() == firstID {
		t.Fatal("retry reused service reservation")
	}
	encoded, err := builder(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	var decoded protocol.InferenceRequestMessage
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.ServiceReservationID != firstID {
		t.Fatal("queued frame changed identity after a new reservation")
	}
	current := providerInferenceWireMessage("request", "ephemeral", "ciphertext", pending)
	if current.ServiceReservationID != pending.ServiceReservationID() {
		t.Fatal("retry frame lost its new service reservation")
	}
}

func TestProviderInferenceWireMessageCarriesObservedRepeatDemand(t *testing.T) {
	reg, provider, first := preparedCacheAttemptForTest(t)
	capability := cacheEligibilityV2Capability("model")
	// Same account, model and prompt: the planner's demand index observes the
	// first plan's 1,024-token stride boundaries and reports the deepest one
	// shared; this plan ends on the stride at 4,096.
	secondPlan := cachePreparationPlanForTest(t, reg, capability)
	if first.CachePlan.RepeatedPrefixTokens != 0 || secondPlan.RepeatedPrefixTokens != 4096 {
		t.Fatalf("repeat demand first=%d second=%d, want 0 then 4096",
			first.CachePlan.RepeatedPrefixTokens, secondPlan.RepeatedPrefixTokens)
	}
	second := &registry.PendingRequest{RequestID: "request-2", Model: "model", CachePlan: secondPlan}
	if err := reg.PrepareCacheAttempt(second, provider); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { reg.ForgetCacheAttempt(second) })
	encoded, err := json.Marshal(providerInferenceWireMessage("request-2", "ephemeral", "ciphertext", second))
	if err != nil {
		t.Fatal(err)
	}
	var decoded protocol.InferenceRequestMessage
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.CacheScope == "" || decoded.CacheRepeatedPrefixTokens == nil || *decoded.CacheRepeatedPrefixTokens != 4096 {
		t.Fatalf("repeated plan lost its demand on the wire: %+v", decoded)
	}
	for _, leaked := range []string{secondPlan.Boundaries[0].ChainHash, "chain_hash", "boundaries"} {
		if strings.Contains(string(encoded), leaked) {
			t.Fatalf("wire frame carries prompt-derived identifier %q: %s", leaked, encoded)
		}
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
		message.CacheRepeatedPrefixTokens != nil ||
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
			if message.CacheScope != "" || message.CacheReceiptNonce != "" || message.PrefixCacheProtocol != 0 || message.CacheReceiptBoundaryMode != "" || message.CacheRepeatedPrefixTokens != nil {
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
