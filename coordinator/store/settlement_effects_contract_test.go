package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func setupSettlementEvidence(t *testing.T, backend string, st Store, id string, includeLoser bool) (*settlementContract, *RequestSettlement, RequestAttempt, RequestAttempt, string) {
	t.Helper()
	c, request, primary, backup := setupSettlementRace(t, backend, st, id)
	if _, inserted, err := st.SelectRequestWinner(context.Background(), WinnerSelection{
		ClientRequestID: request.ClientRequestID, ProviderRequestID: primary.ProviderRequestID,
		ExpectedEpoch: 0, IngressSequence: 1,
	}); err != nil || !inserted {
		t.Fatalf("select settlement winner = %v/%v", inserted, err)
	}
	winnerTerminal := c.terminal(request.ClientRequestID, primary.ProviderRequestID, 2, "complete", 10)
	winnerTerminal.Envelope = "inference_complete"
	winnerTerminal.Cause = "stop"
	winnerTerminal.TerminationReason = "stop"
	if _, inserted, err := claimContractTerminal(t, st, winnerTerminal, nil); err != nil || !inserted {
		t.Fatalf("claim settlement winner = %v/%v", inserted, err)
	}
	if includeLoser {
		loser, _ := st.GetRequestAttempt(context.Background(), request.ClientRequestID, backup.ProviderRequestID)
		if _, inserted, err := claimContractTerminal(t, st, cancelledContractTerminal(c, request.ClientRequestID, *loser, 3), nil); err != nil || !inserted {
			t.Fatalf("claim settlement loser = %v/%v", inserted, err)
		}
	}
	clientSnapshot, clientHash := settlementSnapshot(t, map[string]any{
		"request":  request.ClientRequestID,
		"delivery": "confirmed",
	})
	if _, changed, err := st.RecordDeliveryResult(context.Background(), request.ClientRequestID, clientHash, DeliveryStateConfirmed, clientSnapshot); err != nil || !changed {
		t.Fatalf("record client snapshot = %v/%v", changed, err)
	}
	return c, request, primary, backup, clientHash
}

func validSettlementPlan(c *settlementContract, request *RequestSettlement, winner RequestAttempt) []SettlementEffect {
	chargeID := request.ClientRequestID + ":charge"
	return []SettlementEffect{
		{
			EffectID: request.ClientRequestID + ":charge", ClientRequestID: request.ClientRequestID,
			Type: EffectConsumerCharge, Beneficiary: c.account,
			IdempotencyKey: request.ClientRequestID + ":charge", AmountMicroUSD: 300,
		},
		{
			EffectID: request.ClientRequestID + ":refund", ClientRequestID: request.ClientRequestID,
			Type: EffectConsumerRefund, Beneficiary: c.account,
			IdempotencyKey: request.ClientRequestID + ":refund", AmountMicroUSD: 200,
			DependsOn: []string{chargeID},
		},
		{
			EffectID: request.ClientRequestID + ":payout", ClientRequestID: request.ClientRequestID,
			ProviderRequestID: winner.ProviderRequestID, Type: EffectProviderPayout,
			TargetKind: "account", Beneficiary: c.prefix + "-provider-account",
			IdempotencyKey: request.ClientRequestID + ":payout", AmountMicroUSD: 240,
			DependsOn: []string{chargeID},
		},
	}
}

func normalizedValidSettlementPlan(c *settlementContract, request *RequestSettlement, winner RequestAttempt) []SettlementEffect {
	plan := validSettlementPlan(c, request, winner)
	chargeID := plan[0].EffectID
	plan[1].DependsOn = []string{chargeID}
	plan[2].DependsOn = []string{chargeID}
	return plan
}

func sealContractSettlement(t *testing.T, st Store, requestID, clientHash string, plan []SettlementEffect) (*RequestSettlement, jsonSnapshot) {
	t.Helper()
	snapshot, hash := settlementSnapshot(t, map[string]any{
		"request":              requestID,
		"client_snapshot_hash": clientHash,
		"effect_count":         len(plan),
	})
	stored, changed, err := st.SealSettlementEffects(context.Background(), requestID, clientHash, hash, snapshot, plan)
	if err != nil || !changed {
		t.Fatalf("seal settlement = %#v/%v/%v", stored, changed, err)
	}
	return stored, jsonSnapshot{raw: snapshot, hash: hash}
}

type jsonSnapshot struct {
	raw  []byte
	hash string
}

func TestSettlementStoreSettlementSealRequiresAllEvidenceAndFunding(t *testing.T) {
	for backend, st := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			c, request, winner, loser, clientHash := setupSettlementEvidence(t, backend, st, "seal", false)
			plan := normalizedValidSettlementPlan(c, request, winner)
			snapshot, hash := settlementSnapshot(t, map[string]any{"plan": "valid"})
			_, _, err := st.SealSettlementEffects(context.Background(), request.ClientRequestID, clientHash, hash, snapshot, plan)
			requireErrorIs(t, err, ErrInvalidTransition)

			loserRow, _ := st.GetRequestAttempt(context.Background(), request.ClientRequestID, loser.ProviderRequestID)
			if _, inserted, err := claimContractTerminal(t, st, cancelledContractTerminal(c, request.ClientRequestID, *loserRow, 3), nil); err != nil || !inserted {
				t.Fatalf("claim missing loser evidence = %v/%v", inserted, err)
			}

			withoutFundingDependency := append([]SettlementEffect(nil), plan...)
			withoutFundingDependency[2].DependsOn = nil
			_, _, err = st.SealSettlementEffects(context.Background(), request.ClientRequestID, clientHash, hash, snapshot, withoutFundingDependency)
			requireErrorIs(t, err, ErrInvalidTransition)

			excessPayout := append([]SettlementEffect(nil), plan...)
			excessPayout[2].AmountMicroUSD = 301
			_, _, err = st.SealSettlementEffects(context.Background(), request.ClientRequestID, clientHash, hash, snapshot, excessPayout)
			requireErrorIs(t, err, ErrInvalidTransition)

			loserPayout := append([]SettlementEffect(nil), plan...)
			loserPayout[2].ProviderRequestID = loser.ProviderRequestID
			_, _, err = st.SealSettlementEffects(context.Background(), request.ClientRequestID, clientHash, hash, snapshot, loserPayout)
			requireErrorIs(t, err, ErrInvalidTransition)

			missingTarget := append([]SettlementEffect(nil), plan...)
			missingTarget[2].Beneficiary = ""
			_, _, err = st.SealSettlementEffects(context.Background(), request.ClientRequestID, clientHash, hash, snapshot, missingTarget)
			requireErrorIs(t, err, ErrInvalidTransition)

			cyclic := append([]SettlementEffect(nil), plan...)
			cyclic[0].DependsOn = []string{cyclic[2].EffectID}
			_, _, err = st.SealSettlementEffects(context.Background(), request.ClientRequestID, clientHash, hash, snapshot, cyclic)
			requireErrorIs(t, err, ErrInvalidTransition)

			overfunded := append([]SettlementEffect(nil), plan...)
			overfunded[0].AmountMicroUSD = request.ReservedMicroUSD + 1
			_, _, err = st.SealSettlementEffects(context.Background(), request.ClientRequestID, clientHash, hash, snapshot, overfunded)
			requireErrorIs(t, err, ErrInvalidTransition)

			stored, changed, err := st.SealSettlementEffects(context.Background(), request.ClientRequestID, clientHash, hash, snapshot, plan)
			if err != nil || !changed || !stored.EffectsSealed || stored.State != RequestStateSettling {
				t.Fatalf("valid seal = %#v/%v/%v", stored, changed, err)
			}
			_, changed, err = st.SealSettlementEffects(context.Background(), request.ClientRequestID, clientHash, hash, snapshot, plan)
			if err != nil || changed {
				t.Fatalf("seal replay = %v/%v", changed, err)
			}
			changedPlan := append([]SettlementEffect(nil), plan...)
			changedPlan[1].AmountMicroUSD++
			_, _, err = st.SealSettlementEffects(context.Background(), request.ClientRequestID, clientHash, hash, snapshot, changedPlan)
			requireErrorIs(t, err, ErrConflict)
		})
	}
}

func TestSettlementStoreEffectClaimsRespectDependenciesAndLeases(t *testing.T) {
	for backend, st := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			c, request, winner, _, clientHash := setupSettlementEvidence(t, backend, st, "effects", true)
			plan := normalizedValidSettlementPlan(c, request, winner)
			sealContractSettlement(t, st, request.ClientRequestID, clientHash, plan)

			now := c.now.Add(time.Minute)
			claimed, err := st.ClaimReadySettlementEffect(context.Background(), ClaimSettlementEffectParams{
				WorkerID: "worker-a", Now: now, Lease: time.Minute,
			})
			if err != nil || claimed.Type != EffectConsumerCharge || claimed.ApplyAttempts != 1 {
				t.Fatalf("first effect claim = %#v, %v", claimed, err)
			}
			if _, err := st.ClaimReadySettlementEffect(context.Background(), ClaimSettlementEffectParams{
				WorkerID: "worker-b", Now: now.Add(30 * time.Second), Lease: time.Minute,
			}); !errors.Is(err, ErrNotFound) {
				t.Fatalf("live lease was stolen: %v", err)
			}

			reclaimed, err := st.ClaimReadySettlementEffect(context.Background(), ClaimSettlementEffectParams{
				WorkerID: "worker-b", Now: now.Add(time.Minute + time.Second), Lease: time.Minute,
			})
			if err != nil || reclaimed.EffectID != claimed.EffectID || reclaimed.ApplyAttempts != 2 {
				t.Fatalf("expired lease reclaim = %#v, %v", reclaimed, err)
			}
			_, _, err = st.CompleteSettlementEffect(context.Background(), CompleteSettlementEffectParams{
				EffectID: claimed.EffectID, IdempotencyKey: claimed.IdempotencyKey,
				WorkerID: "worker-a", State: EffectStateApplied,
			})
			requireErrorIs(t, err, ErrInvalidTransition)
			if _, changed, err := st.CompleteSettlementEffect(context.Background(), CompleteSettlementEffectParams{
				EffectID: reclaimed.EffectID, IdempotencyKey: reclaimed.IdempotencyKey,
				WorkerID: "worker-b", State: EffectStateApplied,
			}); err != nil || !changed {
				t.Fatalf("complete funding effect = %v/%v", changed, err)
			}

			completed := map[string]bool{reclaimed.EffectID: true}
			for len(completed) < len(plan) {
				effect, err := st.ClaimReadySettlementEffect(context.Background(), ClaimSettlementEffectParams{
					WorkerID: "worker-c", Now: now.Add(2 * time.Minute), Lease: time.Minute,
				})
				if err != nil {
					t.Fatalf("claim dependent effect: %v", err)
				}
				if effect.Type == EffectProviderPayout && !completed[plan[0].EffectID] {
					t.Fatal("provider payout became ready before consumer charge")
				}
				if _, changed, err := st.CompleteSettlementEffect(context.Background(), CompleteSettlementEffectParams{
					EffectID: effect.EffectID, IdempotencyKey: effect.IdempotencyKey,
					WorkerID: "worker-c", State: EffectStateApplied,
				}); err != nil || !changed {
					t.Fatalf("complete dependent effect %s = %v/%v", effect.EffectID, changed, err)
				}
				completed[effect.EffectID] = true
			}
			settled, err := st.GetRequestSettlement(context.Background(), request.ClientRequestID)
			if err != nil || settled.State != RequestStateSettled {
				t.Fatalf("settled request = %#v, %v", settled, err)
			}
			last := plan[len(plan)-1]
			_, changed, err := st.CompleteSettlementEffect(context.Background(), CompleteSettlementEffectParams{
				EffectID: last.EffectID, IdempotencyKey: last.IdempotencyKey,
				WorkerID: "worker-c", State: EffectStateApplied,
			})
			if err != nil || changed {
				t.Fatalf("effect completion replay = %v/%v", changed, err)
			}
		})
	}
}

func TestSettlementStoreIndeterminateEffectsRecoverAndManualReviewPreservesHolds(t *testing.T) {
	for backend, st := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			c, request, winner, _, clientHash := setupSettlementEvidence(t, backend, st, "effect-recovery", true)
			plan := normalizedValidSettlementPlan(c, request, winner)
			sealContractSettlement(t, st, request.ClientRequestID, clientHash, plan)
			now := c.now.Add(time.Minute)
			claimed, err := st.ClaimReadySettlementEffect(context.Background(), ClaimSettlementEffectParams{
				WorkerID: "worker-a", Now: now, Lease: time.Minute,
			})
			if err != nil {
				t.Fatalf("claim effect for indeterminate: %v", err)
			}
			if _, changed, err := st.CompleteSettlementEffect(context.Background(), CompleteSettlementEffectParams{
				EffectID: claimed.EffectID, IdempotencyKey: claimed.IdempotencyKey,
				WorkerID: "worker-a", State: EffectStateIndeterminate, LastError: "ambiguous result",
			}); err != nil || !changed {
				t.Fatalf("mark effect indeterminate = %v/%v", changed, err)
			}
			reclaimed, err := st.ClaimReadySettlementEffect(context.Background(), ClaimSettlementEffectParams{
				WorkerID: "worker-b", Now: now.Add(time.Second), Lease: time.Minute,
			})
			if err != nil || reclaimed.EffectID != claimed.EffectID || reclaimed.ApplyAttempts != 2 {
				t.Fatalf("reclaim indeterminate = %#v/%v", reclaimed, err)
			}
			if _, changed, err := st.CompleteSettlementEffect(context.Background(), CompleteSettlementEffectParams{
				EffectID: reclaimed.EffectID, IdempotencyKey: reclaimed.IdempotencyKey,
				WorkerID: "worker-b", State: EffectStateManualReview, LastError: "requires operator",
			}); err != nil || !changed {
				t.Fatalf("mark effect manual review = %v/%v", changed, err)
			}
			manual, err := st.GetRequestSettlement(context.Background(), request.ClientRequestID)
			if err != nil || manual.State != RequestStateManualReview {
				t.Fatalf("manual-review request = %#v/%v", manual, err)
			}
			recoverable, err := st.ListRecoverableRequestSettlements(context.Background(), 1000)
			if err != nil {
				t.Fatalf("list recoverable: %v", err)
			}
			for _, candidate := range recoverable {
				if candidate.ClientRequestID == request.ClientRequestID {
					t.Fatal("manual-review request returned to automatic recovery")
				}
			}

			limit := int64(1_000)
			second := c.request("manual-hold-cap", 600)
			second.KeyID = request.KeyID
			_, _, err = st.BeginRequestReservation(context.Background(), BeginRequestReservationParams{
				Request: second, KeyLimitMicroUSD: &limit,
			})
			requireErrorIs(t, err, ErrInsufficientBalance)
		})
	}
}

func TestSettlementStoreRecoveryUsesCommittedSnapshotsOnly(t *testing.T) {
	for backend, st := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			c := newSettlementContract(t, backend, st)
			c.seed(5_000)
			reserved := c.beginRequest(c.request("recover-reserved", 100), false, nil)
			pending := c.beginRequest(c.request("recover-delivery", 100), false, nil)
			if _, _, err := st.RecordDeliveryResult(context.Background(), pending.ClientRequestID, "", DeliveryStatePending, nil); err != nil {
				t.Fatalf("record pending delivery: %v", err)
			}
			recoverable, err := st.ListRecoverableRequestSettlements(context.Background(), 1)
			if err != nil || len(recoverable) != 1 {
				t.Fatalf("limited recovery list = %#v/%v", recoverable, err)
			}
			if recoverable[0].ClientRequestID != reserved.ClientRequestID {
				t.Fatalf("oldest recoverable = %s, want %s", recoverable[0].ClientRequestID, reserved.ClientRequestID)
			}
			all, err := st.ListRecoverableRequestSettlements(context.Background(), 1000)
			if err != nil {
				t.Fatalf("full recovery list: %v", err)
			}
			states := make(map[string]RequestSettlementState)
			for _, candidate := range all {
				states[candidate.ClientRequestID] = candidate.State
			}
			if states[reserved.ClientRequestID] != RequestStateReserved || states[pending.ClientRequestID] != RequestStateDeliveryPending {
				t.Fatalf("recoverable committed states = %#v", states)
			}
		})
	}
}
