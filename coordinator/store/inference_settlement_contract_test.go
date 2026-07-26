package store

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"
)

type settlementContract struct {
	t       *testing.T
	store   Store
	prefix  string
	now     time.Time
	account string
}

func newSettlementContract(t *testing.T, backend string, st Store) *settlementContract {
	t.Helper()
	prefix := uniqueID("settlement-" + backend)
	return &settlementContract{
		t:       t,
		store:   st,
		prefix:  prefix,
		now:     time.Date(2026, 7, 22, 12, 0, 0, 0, time.UTC),
		account: prefix + "-consumer",
	}
}

func (c *settlementContract) seed(amount int64) {
	c.t.Helper()
	if err := c.store.Credit(c.account, amount, LedgerAdminCredit, c.prefix+":seed"); err != nil {
		c.t.Fatalf("seed balance: %v", err)
	}
}

func (c *settlementContract) request(id string, reserved int64) RequestSettlement {
	return RequestSettlement{
		ClientRequestID:   c.prefix + "-" + id,
		ConsumerAccountID: c.account,
		KeyID:             c.prefix + "-key",
		Model:             "test/model",
		PublicModel:       "test-model",
		Endpoint:          "/v1/chat/completions",
		Stream:            true,
		ReservedMicroUSD:  reserved,
		RequestBudgetMS:   int64((30 * time.Minute) / time.Millisecond),
		StartedAt:         c.now,
	}
}

func (c *settlementContract) beginRequest(request RequestSettlement, service bool, limit *int64) *RequestSettlement {
	c.t.Helper()
	created, inserted, err := c.store.BeginRequestReservation(context.Background(), BeginRequestReservationParams{
		Request:          request,
		ServiceHold:      service,
		KeyLimitMicroUSD: limit,
	})
	if err != nil {
		c.t.Fatalf("begin request %s: %v", request.ClientRequestID, err)
	}
	if !inserted {
		c.t.Fatalf("begin request %s did not insert", request.ClientRequestID)
	}
	return created
}

func (c *settlementContract) attempt(requestID, providerRequestID, providerID, role string, ordinal int, topUp int64) RequestAttempt {
	return RequestAttempt{
		ClientRequestID:   requestID,
		ProviderRequestID: c.prefix + "-" + providerRequestID,
		ProviderID:        c.prefix + "-" + providerID,
		Attempt:           ordinal,
		Role:              role,
		ProtocolVersion:   1,
		BudgetMS:          60_000,
		TopUpMicroUSD:     topUp,
	}
}

func (c *settlementContract) beginAttempt(attempt RequestAttempt, limit *int64) *RequestAttempt {
	c.t.Helper()
	created, inserted, err := c.store.BeginAttemptBeforeDispatch(context.Background(), BeginAttemptParams{
		Attempt:          attempt,
		KeyLimitMicroUSD: limit,
	})
	if err != nil {
		c.t.Fatalf("begin attempt %s: %v", attempt.ProviderRequestID, err)
	}
	if !inserted {
		c.t.Fatalf("begin attempt %s did not insert", attempt.ProviderRequestID)
	}
	return created
}

func settlementSnapshot(t *testing.T, values map[string]any) (json.RawMessage, string) {
	t.Helper()
	raw, err := json.Marshal(values)
	if err != nil {
		t.Fatalf("marshal snapshot: %v", err)
	}
	return raw, HashSettlementSnapshot(raw)
}

func (c *settlementContract) terminal(requestID, providerRequestID string, ingress uint64, kind string, completionTokens int) AttemptTerminal {
	c.t.Helper()
	raw, hash := settlementSnapshot(c.t, map[string]any{
		"request": requestID,
		"attempt": providerRequestID,
		"ingress": ingress,
		"kind":    kind,
		"tokens":  completionTokens,
	})
	return AttemptTerminal{
		ClientRequestID:      requestID,
		ProviderRequestID:    providerRequestID,
		IngressSequence:      ingress,
		SnapshotHash:         hash,
		Snapshot:             CanonicalSnapshot(raw),
		MetadataVersion:      1,
		Envelope:             "inference_error",
		Kind:                 kind,
		Cause:                "provider_error",
		Stage:                "decode",
		Source:               "provider",
		AdmissionState:       "running",
		PromptTokens:         10,
		CompletionTokens:     completionTokens,
		LastCompletionTokens: completionTokens,
	}
}

func requireErrorIs(t *testing.T, err, target error) {
	t.Helper()
	if !errors.Is(err, target) {
		t.Fatalf("error = %v, want %v", err, target)
	}
}

func TestSettlementStoreReservationCommitBeforeDispatch(t *testing.T) {
	for backend, st := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			c := newSettlementContract(t, backend, st)
			c.seed(2_000)
			request := c.request("reservation", 400)
			created := c.beginRequest(request, false, nil)
			if created.State != RequestStateReserved || st.GetBalance(c.account) != 1_600 {
				t.Fatalf("reservation state/balance = %s/%d", created.State, st.GetBalance(c.account))
			}

			replayed, inserted, err := st.BeginRequestReservation(context.Background(), BeginRequestReservationParams{Request: request})
			if err != nil || inserted || replayed.ClientRequestID != request.ClientRequestID {
				t.Fatalf("idempotent reservation = inserted %v, err %v", inserted, err)
			}
			if got := st.GetBalance(c.account); got != 1_600 {
				t.Fatalf("balance after replay = %d, want 1600", got)
			}

			conflict := request
			conflict.Model = "other/model"
			_, _, err = st.BeginRequestReservation(context.Background(), BeginRequestReservationParams{Request: conflict})
			requireErrorIs(t, err, ErrConflict)
			if got := st.GetBalance(c.account); got != 1_600 {
				t.Fatalf("balance after conflict = %d, want 1600", got)
			}

			insufficient := c.request("insufficient", 2_001)
			_, _, err = st.BeginRequestReservation(context.Background(), BeginRequestReservationParams{Request: insufficient})
			requireErrorIs(t, err, ErrInsufficientBalance)
			if _, err := st.GetRequestSettlement(context.Background(), insufficient.ClientRequestID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("insufficient request persisted: %v", err)
			}

			effects, err := st.ListSettlementEffects(context.Background(), request.ClientRequestID)
			if err != nil || len(effects) != 1 || effects[0].Type != EffectBaseReservationDebit || effects[0].State != EffectStateApplied {
				t.Fatalf("base effects = %#v, err %v", effects, err)
			}
		})
	}
}

func TestSettlementStoreAttemptCommitBeforeSend(t *testing.T) {
	for backend, st := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			c := newSettlementContract(t, backend, st)
			c.seed(2_000)
			request := c.beginRequest(c.request("attempt", 400), false, nil)
			primary := c.attempt(request.ClientRequestID, "provider-request-0", "provider-0", "primary", 0, 100)
			created := c.beginAttempt(primary, nil)
			if created.State != AttemptStatePendingDispatch || st.GetBalance(c.account) != 1_500 {
				t.Fatalf("attempt state/balance = %s/%d", created.State, st.GetBalance(c.account))
			}

			replayed, inserted, err := st.BeginAttemptBeforeDispatch(context.Background(), BeginAttemptParams{Attempt: primary})
			if err != nil || inserted || replayed.ProviderRequestID != primary.ProviderRequestID {
				t.Fatalf("idempotent attempt = inserted %v, err %v", inserted, err)
			}
			if got := st.GetBalance(c.account); got != 1_500 {
				t.Fatalf("balance after attempt replay = %d, want 1500", got)
			}

			conflict := primary
			conflict.ProviderID = c.prefix + "-other-provider"
			_, _, err = st.BeginAttemptBeforeDispatch(context.Background(), BeginAttemptParams{Attempt: conflict})
			requireErrorIs(t, err, ErrConflict)

			ordinalConflict := c.attempt(request.ClientRequestID, "provider-request-other", "provider-other", "primary", 0, 100)
			_, _, err = st.BeginAttemptBeforeDispatch(context.Background(), BeginAttemptParams{Attempt: ordinalConflict})
			requireErrorIs(t, err, ErrConflict)
			if got := st.GetBalance(c.account); got != 1_500 {
				t.Fatalf("balance after attempt conflicts = %d, want 1500", got)
			}

			backup := c.attempt(request.ClientRequestID, "provider-request-backup", "provider-backup", "backup", 0, 0)
			c.beginAttempt(backup, nil)
			if err := st.MarkAttemptDispatched(context.Background(), request.ClientRequestID, backup.ProviderRequestID, c.now.Add(time.Second)); err != nil {
				t.Fatalf("mark dispatched: %v", err)
			}
			if err := st.MarkAttemptDispatched(context.Background(), request.ClientRequestID, backup.ProviderRequestID, c.now.Add(time.Second)); err != nil {
				t.Fatalf("idempotent mark dispatched: %v", err)
			}

			effects, err := st.ListSettlementEffects(context.Background(), request.ClientRequestID)
			if err != nil || len(effects) != 2 {
				t.Fatalf("effects after top-up/zero attempt = %#v, err %v", effects, err)
			}
			storedRequest, err := st.GetRequestSettlement(context.Background(), request.ClientRequestID)
			if err != nil || storedRequest.ReservedMicroUSD != 500 {
				t.Fatalf("reserved amount = %#v, err %v", storedRequest, err)
			}
		})
	}
}

func TestSettlementStoreActiveHoldsBoundServiceAndKeyAdmission(t *testing.T) {
	for backend, st := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			c := newSettlementContract(t, backend, st)
			c.seed(3_000)

			service := c.request("service-hold", 700)
			service.KeyID = c.prefix + "-service-key"
			c.beginRequest(service, true, nil)
			if got := st.GetBalance(c.account); got != 3_000 {
				t.Fatalf("service hold debited balance: %d", got)
			}
			tooLarge := c.request("service-overbook", 2_400)
			tooLarge.KeyID = c.prefix + "-service-key-2"
			_, _, err := st.BeginRequestReservation(context.Background(), BeginRequestReservationParams{
				Request:     tooLarge,
				ServiceHold: true,
			})
			requireErrorIs(t, err, ErrInsufficientBalance)

			limit := int64(1_000)
			first := c.request("key-hold-first", 600)
			first.KeyID = c.prefix + "-capped-key"
			c.beginRequest(first, false, &limit)
			second := c.request("key-hold-second", 500)
			second.KeyID = first.KeyID
			_, _, err = st.BeginRequestReservation(context.Background(), BeginRequestReservationParams{
				Request:          second,
				KeyLimitMicroUSD: &limit,
			})
			requireErrorIs(t, err, ErrInsufficientBalance)

			topUpTooLarge := c.attempt(first.ClientRequestID, "key-topup-too-large", "provider-key", "primary", 0, 401)
			_, _, err = st.BeginAttemptBeforeDispatch(context.Background(), BeginAttemptParams{
				Attempt:          topUpTooLarge,
				KeyLimitMicroUSD: &limit,
			})
			requireErrorIs(t, err, ErrInsufficientBalance)
			if _, err := st.GetRequestAttempt(context.Background(), first.ClientRequestID, topUpTooLarge.ProviderRequestID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("failed top-up attempt persisted: %v", err)
			}
			stored, err := st.GetRequestSettlement(context.Background(), first.ClientRequestID)
			if err != nil || stored.ReservedMicroUSD != 600 {
				t.Fatalf("reservation changed after failed top-up: %#v, %v", stored, err)
			}
		})
	}
}
