package store

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"time"
)

func settlementAttemptKey(clientRequestID, providerRequestID string) string {
	return clientRequestID + "\x00" + providerRequestID
}

func cloneRaw(src []byte) []byte {
	return append([]byte(nil), src...)
}

func cloneRequestSettlement(src *RequestSettlement) *RequestSettlement {
	if src == nil {
		return nil
	}
	dst := *src
	dst.ClientSnapshot = CanonicalSnapshot(cloneRaw(src.ClientSnapshot))
	dst.SettlementSnapshot = CanonicalSnapshot(cloneRaw(src.SettlementSnapshot))
	return &dst
}

func cloneRequestAttempt(src *RequestAttempt) *RequestAttempt {
	if src == nil {
		return nil
	}
	dst := *src
	if src.DispatchedAt != nil {
		t := *src.DispatchedAt
		dst.DispatchedAt = &t
	}
	return &dst
}

func cloneAttemptTerminal(src *AttemptTerminal) *AttemptTerminal {
	if src == nil {
		return nil
	}
	dst := *src
	dst.Snapshot = CanonicalSnapshot(cloneRaw(src.Snapshot))
	return &dst
}

func cloneSettlementEffect(src *SettlementEffect) SettlementEffect {
	dst := *src
	dst.DependsOn = append([]string(nil), src.DependsOn...)
	dst.Payload = cloneRaw(src.Payload)
	if src.ClaimExpiresAt != nil {
		t := *src.ClaimExpiresAt
		dst.ClaimExpiresAt = &t
	}
	return dst
}

func sameRequestReservation(a, b *RequestSettlement) bool {
	return a.ClientRequestID == b.ClientRequestID &&
		a.ConsumerAccountID == b.ConsumerAccountID &&
		a.KeyID == b.KeyID && a.Model == b.Model && a.PublicModel == b.PublicModel &&
		a.Endpoint == b.Endpoint && a.Stream == b.Stream &&
		a.OpenRouterExact == b.OpenRouterExact && a.FundingKind == b.FundingKind &&
		a.BaseReservedMicroUSD == b.BaseReservedMicroUSD && a.RequestBudgetMS == b.RequestBudgetMS &&
		a.StartedAt.Equal(b.StartedAt)
}

func sameAttemptIdentity(a, b *RequestAttempt) bool {
	return a.ClientRequestID == b.ClientRequestID &&
		a.ProviderRequestID == b.ProviderRequestID && a.ProviderID == b.ProviderID &&
		a.Attempt == b.Attempt && a.Role == b.Role &&
		a.ProtocolVersion == b.ProtocolVersion && a.BudgetMS == b.BudgetMS &&
		a.TopUpMicroUSD == b.TopUpMicroUSD
}

func (s *MemoryStore) requestAttemptsLocked(clientRequestID string) []*RequestAttempt {
	attempts := make([]*RequestAttempt, 0)
	for _, attempt := range s.requestAttempts {
		if attempt.ClientRequestID == clientRequestID {
			attempts = append(attempts, attempt)
		}
	}
	return attempts
}

func allAttemptsTerminal(attempts []*RequestAttempt) bool {
	for _, attempt := range attempts {
		if attempt.State != AttemptStateTerminal {
			return false
		}
	}
	return true
}

func (s *MemoryStore) keySpendSinceLocked(keyID string, since time.Time) int64 {
	ks := s.keySpend[keyID]
	if ks == nil {
		return 0
	}
	if since.IsZero() {
		return ks.lifetime
	}
	startDay := since.UTC().Format("2006-01-02")
	var total int64
	for day, amount := range ks.days {
		if day >= startDay {
			total += amount
		}
	}
	return total
}

func (s *MemoryStore) activeReservedLocked(keyID, accountID string, since time.Time, serviceOnly bool) int64 {
	var total int64
	for _, request := range s.requestSettlements {
		if request.State == RequestStateSettled {
			continue
		}
		if keyID != "" && request.KeyID != keyID {
			continue
		}
		if accountID != "" && request.ConsumerAccountID != accountID {
			continue
		}
		if serviceOnly && request.FundingKind != "service_hold" {
			continue
		}
		if !since.IsZero() && request.StartedAt.Before(since) {
			continue
		}
		total += request.ReservedMicroUSD
	}
	return total
}

func (s *MemoryStore) debitSettlementLocked(accountID string, amount int64, reference string, at time.Time) error {
	if amount < 0 || s.balances[accountID] < amount {
		return ErrInsufficientBalance
	}
	s.balances[accountID] -= amount
	if s.withdrawable[accountID] > s.balances[accountID] {
		s.withdrawable[accountID] = s.balances[accountID]
	}
	s.ledgerSeq++
	s.ledgerEntries = append(s.ledgerEntries, LedgerEntry{
		ID:             s.ledgerSeq,
		AccountID:      accountID,
		Type:           LedgerCharge,
		AmountMicroUSD: -amount,
		BalanceAfter:   s.balances[accountID],
		Reference:      reference,
		CreatedAt:      at,
	})
	return nil
}

func (s *MemoryStore) addEffectLocked(effect SettlementEffect) error {
	if effect.EffectID == "" || effect.ClientRequestID == "" || effect.IdempotencyKey == "" {
		return fmt.Errorf("settlement effect identity is required")
	}
	if existingID, ok := s.effectKeys[effect.IdempotencyKey]; ok {
		if existingID == effect.EffectID {
			return nil
		}
		return ErrConflict
	}
	byID := s.settlementEffects[effect.ClientRequestID]
	if byID == nil {
		byID = make(map[string]*SettlementEffect)
		s.settlementEffects[effect.ClientRequestID] = byID
	}
	if existing := byID[effect.EffectID]; existing != nil {
		if existing.IdempotencyKey == effect.IdempotencyKey && existing.Type == effect.Type && existing.AmountMicroUSD == effect.AmountMicroUSD {
			return nil
		}
		return ErrConflict
	}
	copy := cloneSettlementEffect(&effect)
	byID[effect.EffectID] = &copy
	s.effectKeys[effect.IdempotencyKey] = effect.EffectID
	return nil
}

func (s *MemoryStore) BeginRequestReservation(_ context.Context, params BeginRequestReservationParams) (*RequestSettlement, bool, error) {
	request := params.Request
	if request.ClientRequestID == "" || request.ConsumerAccountID == "" || request.Model == "" || request.Endpoint == "" ||
		request.ReservedMicroUSD < 0 || request.RequestBudgetMS <= 0 || request.StartedAt.IsZero() {
		return nil, false, fmt.Errorf("request settlement identity and nonnegative reservation are required")
	}
	request.StartedAt = request.StartedAt.UTC().Truncate(time.Microsecond)
	if params.ServiceHold {
		request.FundingKind = "service_hold"
	} else {
		request.FundingKind = "ledger"
	}
	request.BaseReservedMicroUSD = request.ReservedMicroUSD

	s.mu.Lock()
	defer s.mu.Unlock()
	if existing := s.requestSettlements[request.ClientRequestID]; existing != nil {
		if !sameRequestReservation(existing, &request) {
			return nil, false, ErrConflict
		}
		return cloneRequestSettlement(existing), false, nil
	}
	if params.KeyLimitMicroUSD != nil && request.KeyID != "" {
		spend := s.keySpendSinceLocked(request.KeyID, params.KeySpendSince)
		spend += s.activeReservedLocked(request.KeyID, "", params.KeySpendSince, false)
		if request.ReservedMicroUSD > *params.KeyLimitMicroUSD-spend {
			return nil, false, ErrInsufficientBalance
		}
	}
	if params.ServiceHold {
		available := s.balances[request.ConsumerAccountID] - s.activeReservedLocked("", request.ConsumerAccountID, time.Time{}, true)
		if available < request.ReservedMicroUSD {
			return nil, false, ErrInsufficientBalance
		}
	} else if err := s.debitSettlementLocked(request.ConsumerAccountID, request.ReservedMicroUSD,
		"settlement:"+request.ClientRequestID+":base", time.Now()); err != nil {
		return nil, false, err
	}

	now := time.Now().UTC()
	request.State = RequestStateReserved
	request.DeliveryState = DeliveryStateNone
	request.TransportState = "T0"
	request.ProtocolState = "V0"
	request.SemanticState = "C0"
	request.CreatedAt = now
	request.UpdatedAt = now
	s.requestSettlements[request.ClientRequestID] = cloneRequestSettlement(&request)
	effectType := EffectBaseReservationDebit
	if params.ServiceHold {
		effectType = EffectServiceHold
	}
	effect := SettlementEffect{
		EffectID:        request.ClientRequestID + ":base",
		ClientRequestID: request.ClientRequestID,
		Type:            effectType,
		Beneficiary:     request.ConsumerAccountID,
		IdempotencyKey:  request.ClientRequestID + ":" + string(effectType),
		AmountMicroUSD:  request.ReservedMicroUSD,
		State:           EffectStateApplied,
		CreatedAt:       now,
		UpdatedAt:       now,
	}
	if err := s.addEffectLocked(effect); err != nil {
		panic("memory settlement base effect conflict after request uniqueness: " + err.Error())
	}
	return cloneRequestSettlement(&request), true, nil
}

func (s *MemoryStore) BeginAttemptBeforeDispatch(_ context.Context, params BeginAttemptParams) (*RequestAttempt, bool, error) {
	attempt := params.Attempt
	if attempt.ClientRequestID == "" || attempt.ProviderRequestID == "" || attempt.ProviderID == "" ||
		attempt.Attempt < 0 || attempt.ProtocolVersion < 0 || attempt.BudgetMS < 0 || attempt.TopUpMicroUSD < 0 {
		return nil, false, fmt.Errorf("attempt identity and nonnegative top-up are required")
	}
	if attempt.Role == "" {
		attempt.Role = "primary"
	}
	key := settlementAttemptKey(attempt.ClientRequestID, attempt.ProviderRequestID)
	s.mu.Lock()
	defer s.mu.Unlock()
	if existing := s.requestAttempts[key]; existing != nil {
		if !sameAttemptIdentity(existing, &attempt) {
			return nil, false, ErrConflict
		}
		return cloneRequestAttempt(existing), false, nil
	}
	request := s.requestSettlements[attempt.ClientRequestID]
	if request == nil {
		return nil, false, ErrNotFound
	}
	if (request.State != RequestStateReserved && request.State != RequestStateActive) || request.FenceCause != "" ||
		request.WinnerAttemptID != "" || request.DeliveryState != DeliveryStateNone || request.EffectsSealed {
		return nil, false, ErrInvalidTransition
	}
	existingAttempts := s.requestAttemptsLocked(attempt.ClientRequestID)
	for _, existing := range existingAttempts {
		if existing.Attempt == attempt.Attempt && existing.Role == attempt.Role {
			return nil, false, ErrConflict
		}
	}
	existingValues := make([]RequestAttempt, 0, len(existingAttempts))
	for _, existing := range existingAttempts {
		existingValues = append(existingValues, *existing)
	}
	if err := validateAttemptCreation(existingValues, attempt); err != nil {
		return nil, false, err
	}
	if attempt.TopUpMicroUSD > 0 {
		if params.KeyLimitMicroUSD != nil && request.KeyID != "" {
			spend := s.keySpendSinceLocked(request.KeyID, params.KeySpendSince)
			spend += s.activeReservedLocked(request.KeyID, "", params.KeySpendSince, false)
			if attempt.TopUpMicroUSD > *params.KeyLimitMicroUSD-spend {
				return nil, false, ErrInsufficientBalance
			}
		}
		if request.FundingKind == "service_hold" {
			available := s.balances[request.ConsumerAccountID] - s.activeReservedLocked("", request.ConsumerAccountID, time.Time{}, true)
			if available < attempt.TopUpMicroUSD {
				return nil, false, ErrInsufficientBalance
			}
		} else if err := s.debitSettlementLocked(request.ConsumerAccountID, attempt.TopUpMicroUSD,
			"settlement:"+attempt.ClientRequestID+":"+attempt.ProviderRequestID+":topup", time.Now()); err != nil {
			return nil, false, err
		}
		request.ReservedMicroUSD += attempt.TopUpMicroUSD
		request.UpdatedAt = time.Now().UTC()
		effect := SettlementEffect{
			EffectID:          attempt.ClientRequestID + ":" + attempt.ProviderRequestID + ":topup",
			ClientRequestID:   attempt.ClientRequestID,
			ProviderRequestID: attempt.ProviderRequestID,
			Type:              EffectAttemptExtraDebit,
			Beneficiary:       request.ConsumerAccountID,
			IdempotencyKey:    attempt.ClientRequestID + ":" + attempt.ProviderRequestID + ":" + string(EffectAttemptExtraDebit),
			AmountMicroUSD:    attempt.TopUpMicroUSD,
			State:             EffectStateApplied,
			CreatedAt:         time.Now().UTC(),
			UpdatedAt:         time.Now().UTC(),
		}
		if err := s.addEffectLocked(effect); err != nil {
			return nil, false, err
		}
	}
	now := time.Now().UTC()
	attempt.State = AttemptStatePendingDispatch
	attempt.Disposition = AttemptDispositionActive
	attempt.WinnerEpoch = request.WinnerEpoch
	if attempt.AdmissionState == "" {
		attempt.AdmissionState = "pre_accept"
	}
	if attempt.CancelState == "" {
		attempt.CancelState = AttemptCancelNone
	}
	attempt.CreatedAt = now
	attempt.UpdatedAt = now
	s.requestAttempts[key] = cloneRequestAttempt(&attempt)
	request.State = RequestStateActive
	request.UpdatedAt = now
	return cloneRequestAttempt(&attempt), true, nil
}

func (s *MemoryStore) MarkAttemptDispatched(_ context.Context, clientRequestID, providerRequestID string, at time.Time) error {
	key := settlementAttemptKey(clientRequestID, providerRequestID)
	s.mu.Lock()
	defer s.mu.Unlock()
	attempt := s.requestAttempts[key]
	if attempt == nil {
		return ErrNotFound
	}
	if attempt.State == AttemptStateDispatched {
		return nil
	}
	if attempt.State != AttemptStatePendingDispatch {
		return ErrInvalidTransition
	}
	if at.IsZero() {
		at = time.Now().UTC()
	}
	attempt.State = AttemptStateDispatched
	attempt.DispatchedAt = &at
	attempt.UpdatedAt = time.Now().UTC()
	return nil
}

func admissionRank(state string) int {
	switch state {
	case "pre_accept":
		return 0
	case "accepted":
		return 1
	case "running":
		return 2
	default:
		return -1
	}
}

func (s *MemoryStore) AdvanceAttemptAdmission(_ context.Context, clientRequestID, providerRequestID, state string) error {
	if admissionRank(state) < 0 {
		return ErrInvalidTransition
	}
	key := settlementAttemptKey(clientRequestID, providerRequestID)
	s.mu.Lock()
	defer s.mu.Unlock()
	attempt := s.requestAttempts[key]
	if attempt == nil {
		return ErrNotFound
	}
	if attempt.State == AttemptStateTerminal {
		return ErrInvalidTransition
	}
	if admissionRank(state) < admissionRank(attempt.AdmissionState) {
		return ErrInvalidTransition
	}
	attempt.AdmissionState = state
	attempt.UpdatedAt = time.Now().UTC()
	return nil
}

func (s *MemoryStore) SelectRequestWinner(_ context.Context, selection WinnerSelection) (*RequestSettlement, bool, error) {
	if selection.ClientRequestID == "" || selection.ProviderRequestID == "" || selection.IngressSequence == 0 {
		return nil, false, ErrInvalidTransition
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	request := s.requestSettlements[selection.ClientRequestID]
	if request == nil {
		return nil, false, ErrNotFound
	}
	if request.WinnerAttemptID != "" {
		if request.WinnerAttemptID == selection.ProviderRequestID && request.WinnerEpoch == selection.ExpectedEpoch &&
			request.WinnerIngressSequence == selection.IngressSequence {
			return cloneRequestSettlement(request), false, nil
		}
		return nil, false, ErrConflict
	}
	if request.WinnerEpoch != selection.ExpectedEpoch || request.FenceCause != "" || request.EffectsSealed ||
		selection.IngressSequence <= request.LastIngressSequence {
		return nil, false, ErrInvalidTransition
	}
	winner := s.requestAttempts[settlementAttemptKey(selection.ClientRequestID, selection.ProviderRequestID)]
	if winner == nil || winner.Disposition != AttemptDispositionActive || winner.State == AttemptStateTerminal {
		return nil, false, ErrInvalidTransition
	}
	request.WinnerAttemptID = selection.ProviderRequestID
	request.WinnerIngressSequence = selection.IngressSequence
	request.LastIngressSequence = selection.IngressSequence
	request.UpdatedAt = time.Now().UTC()
	winner.Disposition = AttemptDispositionWinner
	winner.WinnerEpoch = request.WinnerEpoch
	winner.UpdatedAt = request.UpdatedAt
	for _, peer := range s.requestAttemptsLocked(selection.ClientRequestID) {
		if peer.ProviderRequestID == selection.ProviderRequestID || peer.Disposition != AttemptDispositionActive ||
			peer.WinnerEpoch != request.WinnerEpoch {
			continue
		}
		peer.Disposition = AttemptDispositionSpeculativeLoser
		peer.CancelState = AttemptCancelPending
		peer.CancelReason = "speculative_loser"
		peer.FenceVersion = 0
		peer.FenceSequence = selection.IngressSequence
		peer.UpdatedAt = request.UpdatedAt
	}
	return cloneRequestSettlement(request), true, nil
}

func (s *MemoryStore) ReleaseRequestWinnerForRetry(_ context.Context, clientRequestID, providerRequestID string, epoch int64) (*RequestSettlement, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	request := s.requestSettlements[clientRequestID]
	if request == nil {
		return nil, false, ErrNotFound
	}
	if request.WinnerAttemptID == "" && request.WinnerEpoch == epoch+1 {
		return cloneRequestSettlement(request), false, nil
	}
	if request.WinnerAttemptID != providerRequestID || request.WinnerEpoch != epoch ||
		request.ProtocolState != "V0" || request.SemanticState != "C0" ||
		request.FenceCause != "" || request.DeliveryState != DeliveryStateNone {
		return nil, false, ErrInvalidTransition
	}
	attempt := s.requestAttempts[settlementAttemptKey(clientRequestID, providerRequestID)]
	if attempt == nil || attempt.Disposition != AttemptDispositionWinner || attempt.State != AttemptStateTerminal {
		return nil, false, ErrInvalidTransition
	}
	for _, peer := range s.requestAttemptsLocked(clientRequestID) {
		if peer.ProviderRequestID != providerRequestID && peer.State != AttemptStateTerminal {
			return nil, false, ErrInvalidTransition
		}
	}
	attempt.Disposition = AttemptDispositionFailedRetry
	attempt.UpdatedAt = time.Now().UTC()
	request.WinnerAttemptID = ""
	request.WinnerIngressSequence = 0
	request.WinnerEpoch++
	request.State = RequestStateActive
	request.UpdatedAt = attempt.UpdatedAt
	return cloneRequestSettlement(request), true, nil
}

func (s *MemoryStore) FenceRequest(_ context.Context, fence RequestFence) (*RequestSettlement, bool, error) {
	if fence.ClientRequestID == "" || fence.Cause == "" || fence.Sequence == 0 || fence.FenceVersion <= 0 {
		return nil, false, ErrInvalidTransition
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	request := s.requestSettlements[fence.ClientRequestID]
	if request == nil {
		return nil, false, ErrNotFound
	}
	if request.FenceCause != "" {
		if request.FenceCause == fence.Cause && request.FenceVersion == fence.FenceVersion && request.FenceSequence == fence.Sequence {
			return cloneRequestSettlement(request), false, nil
		}
		return nil, false, ErrConflict
	}
	if request.EffectsSealed || fence.Sequence <= request.LastIngressSequence {
		return nil, false, ErrInvalidTransition
	}
	live := make(map[string]*RequestAttempt)
	for _, attempt := range s.requestAttemptsLocked(fence.ClientRequestID) {
		if attempt.State != AttemptStateTerminal {
			live[attempt.ProviderRequestID] = attempt
		}
	}
	if len(fence.AttemptIDs) > 0 {
		if len(fence.AttemptIDs) != len(live) {
			return nil, false, ErrInvalidTransition
		}
		seen := make(map[string]struct{}, len(fence.AttemptIDs))
		for _, attemptID := range fence.AttemptIDs {
			if _, duplicate := seen[attemptID]; duplicate || live[attemptID] == nil {
				return nil, false, ErrInvalidTransition
			}
			seen[attemptID] = struct{}{}
		}
	}
	now := time.Now().UTC()
	for _, attempt := range live {
		if attempt.CancelState == AttemptCancelNone {
			attempt.CancelState = AttemptCancelPending
			attempt.CancelReason = fence.Cause
			attempt.FenceVersion = fence.FenceVersion
			attempt.FenceSequence = fence.Sequence
		}
		if attempt.Disposition == AttemptDispositionActive {
			attempt.Disposition = AttemptDispositionCancelledByFence
		}
		attempt.UpdatedAt = now
	}
	request.FenceCause = fence.Cause
	request.FenceVersion = fence.FenceVersion
	request.FenceSequence = fence.Sequence
	request.LastIngressSequence = fence.Sequence
	if request.State == RequestStateReserved || request.State == RequestStateActive || request.State == RequestStateTerminalRecorded {
		request.State = RequestStateFenced
	}
	request.UpdatedAt = now
	return cloneRequestSettlement(request), true, nil
}

func (s *MemoryStore) TransitionAttemptCancel(_ context.Context, transition AttemptCancelTransition) (bool, error) {
	if transition.ClientRequestID == "" || transition.ProviderRequestID == "" || transition.FenceVersion < 0 ||
		transition.FenceSequence == 0 || !validCancelTransition(transition.From, transition.To) {
		return false, ErrInvalidTransition
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	attempt := s.requestAttempts[settlementAttemptKey(transition.ClientRequestID, transition.ProviderRequestID)]
	if attempt == nil {
		return false, ErrNotFound
	}
	if attempt.FenceVersion != transition.FenceVersion || attempt.FenceSequence != transition.FenceSequence {
		return false, ErrInvalidTransition
	}
	if attempt.CancelState == transition.To {
		return false, nil
	}
	if attempt.CancelState != transition.From {
		return false, ErrInvalidTransition
	}
	attempt.CancelState = transition.To
	attempt.UpdatedAt = time.Now().UTC()
	return true, nil
}

func (s *MemoryStore) ClaimAttemptTerminal(_ context.Context, claim AttemptTerminalClaim) (*AttemptTerminal, bool, error) {
	terminal := claim.Terminal
	if terminal.ClientRequestID == "" || terminal.ProviderRequestID == "" || terminal.IngressSequence == 0 ||
		terminal.PromptTokens < 0 || terminal.CompletionTokens < 0 || terminal.ReasoningTokens < 0 ||
		terminal.LastCompletionTokens < 0 || terminal.LastCompletionTokens > terminal.CompletionTokens ||
		!validSettlementSnapshot(terminal.Snapshot, terminal.SnapshotHash) {
		return nil, false, ErrInvalidTransition
	}
	key := settlementAttemptKey(terminal.ClientRequestID, terminal.ProviderRequestID)
	s.mu.Lock()
	defer s.mu.Unlock()
	if existing := s.attemptTerminals[key]; existing != nil {
		if existing.SnapshotHash != terminal.SnapshotHash {
			return cloneAttemptTerminal(existing), false, ErrConflict
		}
		return cloneAttemptTerminal(existing), false, nil
	}
	request := s.requestSettlements[terminal.ClientRequestID]
	if request == nil {
		return nil, false, ErrNotFound
	}
	if request.EffectsSealed || terminal.IngressSequence <= request.LastIngressSequence {
		return nil, false, ErrInvalidTransition
	}
	attempt := s.requestAttempts[key]
	if attempt == nil {
		return nil, false, ErrNotFound
	}
	if attempt.State == AttemptStateTerminal {
		return nil, false, ErrInvalidTransition
	}
	if terminal.AdmissionState == "" {
		terminal.AdmissionState = attempt.AdmissionState
	}
	if admissionRank(terminal.AdmissionState) < admissionRank(attempt.AdmissionState) {
		return nil, false, ErrInvalidTransition
	}
	if terminal.Kind == "cancelled" {
		if attempt.CancelState == AttemptCancelNone || terminal.RequestFenceVersion != attempt.FenceVersion ||
			terminal.RequestFenceSequence != attempt.FenceSequence || terminal.CancelReason != attempt.CancelReason {
			return nil, false, ErrInvalidTransition
		}
	}
	if claim.EmptyWinner != nil {
		selection := claim.EmptyWinner
		if selection.ClientRequestID != terminal.ClientRequestID || selection.ProviderRequestID != terminal.ProviderRequestID ||
			selection.IngressSequence != terminal.IngressSequence || selection.ExpectedEpoch != request.WinnerEpoch ||
			request.WinnerAttemptID != "" || request.FenceCause != "" || attempt.Disposition != AttemptDispositionActive ||
			terminal.Kind != "complete" || terminal.CompletionTokens != 0 || terminal.LastCompletionTokens != 0 {
			return nil, false, ErrInvalidTransition
		}
	}
	terminal.CreatedAt = time.Now().UTC()
	s.attemptTerminals[key] = cloneAttemptTerminal(&terminal)
	attempt.State = AttemptStateTerminal
	attempt.AdmissionState = terminal.AdmissionState
	attempt.UpdatedAt = terminal.CreatedAt
	if terminal.Kind == "cancelled" {
		attempt.CancelState = AttemptCancelAcknowledged
	}
	request.LastIngressSequence = terminal.IngressSequence
	request.UpdatedAt = terminal.CreatedAt
	if claim.EmptyWinner != nil {
		request.WinnerAttemptID = terminal.ProviderRequestID
		request.WinnerIngressSequence = terminal.IngressSequence
		attempt.Disposition = AttemptDispositionWinner
		attempt.WinnerEpoch = request.WinnerEpoch
		for _, peer := range s.requestAttemptsLocked(terminal.ClientRequestID) {
			if peer.ProviderRequestID == terminal.ProviderRequestID || peer.Disposition != AttemptDispositionActive ||
				peer.WinnerEpoch != request.WinnerEpoch {
				continue
			}
			peer.Disposition = AttemptDispositionSpeculativeLoser
			peer.CancelState = AttemptCancelPending
			peer.CancelReason = "speculative_loser"
			peer.FenceVersion = 0
			peer.FenceSequence = terminal.IngressSequence
			peer.UpdatedAt = terminal.CreatedAt
		}
	}
	if allAttemptsTerminal(s.requestAttemptsLocked(terminal.ClientRequestID)) &&
		(request.State == RequestStateReserved || request.State == RequestStateActive) {
		request.State = RequestStateTerminalRecorded
	}
	return cloneAttemptTerminal(&terminal), true, nil
}

func (s *MemoryStore) AdvanceDeliveryCheckpoint(_ context.Context, checkpoint DeliveryCheckpoint) (*RequestSettlement, bool, error) {
	if checkpoint.ClientRequestID == "" || checkpoint.IngressSequence == 0 || checkpoint.WrittenCompletionTokens < 0 ||
		deliveryStateRank(checkpoint.TransportState, "T0", "T1", "") < 0 ||
		deliveryStateRank(checkpoint.ProtocolState, "V0", "V1", "V2") < 0 ||
		deliveryStateRank(checkpoint.SemanticState, "C0", "C1", "") < 0 {
		return nil, false, ErrInvalidTransition
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	request := s.requestSettlements[checkpoint.ClientRequestID]
	if request == nil {
		return nil, false, ErrNotFound
	}
	if request.ClientSnapshotHash != "" || request.EffectsSealed || request.DeliveryState != DeliveryStateNone {
		return nil, false, ErrInvalidTransition
	}
	if checkpoint.IngressSequence == request.WrittenIngressSequence {
		if checkpoint.TransportState == request.TransportState && checkpoint.ProtocolState == request.ProtocolState &&
			checkpoint.SemanticState == request.SemanticState && checkpoint.WrittenChunkSequence == request.WrittenChunkSequence &&
			checkpoint.WrittenCompletionTokens == request.WrittenCompletionTokens && checkpoint.WrittenCommitment == request.WrittenCommitment {
			return cloneRequestSettlement(request), false, nil
		}
		return nil, false, ErrConflict
	}
	if checkpoint.IngressSequence < request.WrittenIngressSequence ||
		(request.FenceCause != "" && checkpoint.IngressSequence > request.FenceSequence) ||
		deliveryStateRank(checkpoint.TransportState, "T0", "T1", "") < deliveryStateRank(request.TransportState, "T0", "T1", "") ||
		deliveryStateRank(checkpoint.ProtocolState, "V0", "V1", "V2") < deliveryStateRank(request.ProtocolState, "V0", "V1", "V2") ||
		deliveryStateRank(checkpoint.SemanticState, "C0", "C1", "") < deliveryStateRank(request.SemanticState, "C0", "C1", "") ||
		checkpoint.WrittenChunkSequence < request.WrittenChunkSequence ||
		checkpoint.WrittenCompletionTokens < request.WrittenCompletionTokens {
		return nil, false, ErrInvalidTransition
	}
	if checkpoint.ProtocolState != "V0" && checkpoint.TransportState != "T1" {
		return nil, false, ErrInvalidTransition
	}
	if checkpoint.SemanticState == "C1" && checkpoint.ProtocolState == "V0" {
		return nil, false, ErrInvalidTransition
	}
	providerProgress := checkpoint.WrittenChunkSequence > request.WrittenChunkSequence ||
		checkpoint.WrittenCompletionTokens > request.WrittenCompletionTokens || checkpoint.SemanticState != request.SemanticState
	if checkpoint.ProviderRequestID != "" {
		if checkpoint.ProviderRequestID != request.WinnerAttemptID {
			return nil, false, ErrInvalidTransition
		}
	} else if providerProgress {
		return nil, false, ErrInvalidTransition
	}
	if checkpoint.WrittenChunkSequence > request.WrittenChunkSequence {
		if !validLowerHexDigest(checkpoint.WrittenCommitment) {
			return nil, false, ErrInvalidTransition
		}
	} else if checkpoint.WrittenCommitment != request.WrittenCommitment {
		return nil, false, ErrInvalidTransition
	}
	request.TransportState = checkpoint.TransportState
	request.ProtocolState = checkpoint.ProtocolState
	request.SemanticState = checkpoint.SemanticState
	request.WrittenIngressSequence = checkpoint.IngressSequence
	request.WrittenChunkSequence = checkpoint.WrittenChunkSequence
	request.WrittenCompletionTokens = checkpoint.WrittenCompletionTokens
	request.WrittenCommitment = checkpoint.WrittenCommitment
	if checkpoint.IngressSequence > request.LastIngressSequence {
		request.LastIngressSequence = checkpoint.IngressSequence
	}
	request.UpdatedAt = time.Now().UTC()
	return cloneRequestSettlement(request), true, nil
}

func (s *MemoryStore) RecordDeliveryResult(_ context.Context, clientRequestID, snapshotHash string, state DeliveryState, snapshot json.RawMessage) (*RequestSettlement, bool, error) {
	if clientRequestID == "" || (state != DeliveryStatePending && state != DeliveryStateConfirmed &&
		state != DeliveryStateFailed && state != DeliveryStateIndeterminate) ||
		(state != DeliveryStatePending && !validSettlementSnapshot(snapshot, snapshotHash)) {
		return nil, false, ErrInvalidTransition
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	request := s.requestSettlements[clientRequestID]
	if request == nil {
		return nil, false, ErrNotFound
	}
	if state == DeliveryStatePending {
		if request.DeliveryState == DeliveryStatePending {
			return cloneRequestSettlement(request), false, nil
		}
		if request.DeliveryState != DeliveryStateNone {
			return nil, false, ErrInvalidTransition
		}
		request.DeliveryState = state
		request.State = RequestStateDeliveryPending
		request.UpdatedAt = time.Now().UTC()
		return cloneRequestSettlement(request), true, nil
	}
	if request.ClientSnapshotHash != "" {
		if request.ClientSnapshotHash == snapshotHash && request.DeliveryState == state {
			return cloneRequestSettlement(request), false, nil
		}
		return nil, false, ErrConflict
	}
	if request.DeliveryState != DeliveryStateNone && request.DeliveryState != DeliveryStatePending {
		return nil, false, ErrInvalidTransition
	}
	request.ClientSnapshotHash = snapshotHash
	request.ClientSnapshot = CanonicalSnapshot(cloneRaw(snapshot))
	request.DeliveryState = state
	request.State = RequestStateDeliveryRecorded
	request.UpdatedAt = time.Now().UTC()
	return cloneRequestSettlement(request), true, nil
}

func (s *MemoryStore) SealSettlementEffects(_ context.Context, clientRequestID, clientSnapshotHash, settlementSnapshotHash string, snapshot json.RawMessage, effects []SettlementEffect) (*RequestSettlement, bool, error) {
	if clientRequestID == "" || clientSnapshotHash == "" || !validSettlementSnapshot(snapshot, settlementSnapshotHash) {
		return nil, false, ErrInvalidTransition
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	request := s.requestSettlements[clientRequestID]
	if request == nil {
		return nil, false, ErrNotFound
	}
	if request.ClientSnapshotHash != clientSnapshotHash {
		return nil, false, ErrInvalidTransition
	}
	if request.EffectsSealed {
		existingEffects := make([]SettlementEffect, 0, len(s.settlementEffects[clientRequestID]))
		for _, effect := range s.settlementEffects[clientRequestID] {
			existingEffects = append(existingEffects, cloneSettlementEffect(effect))
		}
		if request.SettlementSnapshotHash == settlementSnapshotHash && sameSealedEffectPlan(existingEffects, effects) {
			return cloneRequestSettlement(request), false, nil
		}
		return nil, false, ErrConflict
	}
	if request.State != RequestStateDeliveryRecorded {
		return nil, false, ErrInvalidTransition
	}
	attemptPointers := s.requestAttemptsLocked(clientRequestID)
	if !allAttemptsTerminal(attemptPointers) {
		return nil, false, ErrInvalidTransition
	}
	attempts := make([]RequestAttempt, 0, len(attemptPointers))
	for _, attempt := range attemptPointers {
		attempts = append(attempts, *cloneRequestAttempt(attempt))
	}
	seenIDs := make(map[string]struct{}, len(effects))
	seenKeys := make(map[string]struct{}, len(effects))
	for i := range effects {
		effect := &effects[i]
		if effect.ClientRequestID != clientRequestID || effect.EffectID == "" || effect.IdempotencyKey == "" || effect.AmountMicroUSD < 0 {
			return nil, false, ErrInvalidTransition
		}
		if _, ok := seenIDs[effect.EffectID]; ok {
			return nil, false, ErrConflict
		}
		if _, ok := seenKeys[effect.IdempotencyKey]; ok {
			return nil, false, ErrConflict
		}
		seenIDs[effect.EffectID] = struct{}{}
		seenKeys[effect.IdempotencyKey] = struct{}{}
	}
	existingEffects := make([]SettlementEffect, 0, len(s.settlementEffects[clientRequestID]))
	for _, effect := range s.settlementEffects[clientRequestID] {
		existingEffects = append(existingEffects, cloneSettlementEffect(effect))
	}
	if err := validateSettlementEffectPlan(request, attempts, existingEffects, effects); err != nil {
		return nil, false, err
	}
	for i := range effects {
		effect := effects[i]
		effect.SealedPlan = true
		if effect.State == "" {
			effect.State = EffectStatePending
		}
		now := time.Now().UTC()
		effect.CreatedAt = now
		effect.UpdatedAt = now
		if err := s.addEffectLocked(effect); err != nil {
			return nil, false, err
		}
	}
	request.SettlementSnapshotHash = settlementSnapshotHash
	request.SettlementSnapshot = CanonicalSnapshot(cloneRaw(snapshot))
	request.EffectsSealed = true
	request.State = RequestStateSettled
	for _, effect := range s.settlementEffects[clientRequestID] {
		if effect.State != EffectStateApplied && effect.State != EffectStateNotApplicable {
			request.State = RequestStateSettling
			break
		}
	}
	request.UpdatedAt = time.Now().UTC()
	return cloneRequestSettlement(request), true, nil
}

func effectDependenciesApplied(effect *SettlementEffect, byID map[string]*SettlementEffect) bool {
	for _, dependency := range effect.DependsOn {
		dep := byID[dependency]
		if dep == nil || dep.State != EffectStateApplied {
			return false
		}
	}
	return true
}

func (s *MemoryStore) ClaimReadySettlementEffect(_ context.Context, params ClaimSettlementEffectParams) (*SettlementEffect, error) {
	if params.WorkerID == "" || params.Lease <= 0 {
		return nil, ErrInvalidTransition
	}
	if params.Now.IsZero() {
		params.Now = time.Now().UTC()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	type candidate struct {
		effect *SettlementEffect
	}
	candidates := make([]candidate, 0)
	for clientID, byID := range s.settlementEffects {
		request := s.requestSettlements[clientID]
		if request == nil || !request.EffectsSealed || request.State != RequestStateSettling {
			continue
		}
		for _, effect := range byID {
			readyState := effect.State == EffectStatePending || effect.State == EffectStateIndeterminate ||
				(effect.State == EffectStateApplying && effect.ClaimExpiresAt != nil && !effect.ClaimExpiresAt.After(params.Now))
			if readyState && effectDependenciesApplied(effect, byID) {
				candidates = append(candidates, candidate{effect: effect})
			}
		}
	}
	if len(candidates) == 0 {
		return nil, ErrNotFound
	}
	sort.Slice(candidates, func(i, j int) bool {
		a, b := candidates[i].effect, candidates[j].effect
		if a.CreatedAt.Equal(b.CreatedAt) {
			return a.EffectID < b.EffectID
		}
		return a.CreatedAt.Before(b.CreatedAt)
	})
	effect := candidates[0].effect
	expires := params.Now.Add(params.Lease)
	effect.State = EffectStateApplying
	effect.ClaimOwner = params.WorkerID
	effect.ClaimExpiresAt = &expires
	effect.ApplyAttempts++
	effect.UpdatedAt = params.Now
	copy := cloneSettlementEffect(effect)
	return &copy, nil
}

func (s *MemoryStore) CompleteSettlementEffect(_ context.Context, params CompleteSettlementEffectParams) (*SettlementEffect, bool, error) {
	if params.EffectID == "" || params.IdempotencyKey == "" || params.WorkerID == "" ||
		(params.State != EffectStateApplied && params.State != EffectStateNotApplicable &&
			params.State != EffectStateIndeterminate && params.State != EffectStateManualReview) {
		return nil, false, ErrInvalidTransition
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if effectID := s.effectKeys[params.IdempotencyKey]; effectID == "" {
		return nil, false, ErrNotFound
	} else if effectID != params.EffectID {
		return nil, false, ErrConflict
	}
	var effect *SettlementEffect
	for _, byID := range s.settlementEffects {
		if byID[params.EffectID] != nil {
			effect = byID[params.EffectID]
			break
		}
	}
	if effect == nil {
		return nil, false, ErrNotFound
	}
	if effect.State == params.State && effect.ClaimOwner == "" {
		copy := cloneSettlementEffect(effect)
		return &copy, false, nil
	}
	if effect.State != EffectStateApplying || effect.ClaimOwner != params.WorkerID {
		return nil, false, ErrInvalidTransition
	}
	now := time.Now().UTC()
	effect.State = params.State
	effect.LastError = params.LastError
	effect.ClaimOwner = ""
	effect.ClaimExpiresAt = nil
	effect.UpdatedAt = now
	request := s.requestSettlements[effect.ClientRequestID]
	if request == nil {
		return nil, false, ErrNotFound
	}
	if params.State == EffectStateManualReview {
		request.State = RequestStateManualReview
	} else if params.State == EffectStateApplied || params.State == EffectStateNotApplicable {
		settled := request.EffectsSealed
		for _, candidate := range s.settlementEffects[effect.ClientRequestID] {
			if candidate.State != EffectStateApplied && candidate.State != EffectStateNotApplicable {
				settled = false
				break
			}
		}
		if settled {
			request.State = RequestStateSettled
		}
	}
	request.UpdatedAt = now
	copy := cloneSettlementEffect(effect)
	return &copy, true, nil
}

func (s *MemoryStore) GetRequestSettlement(_ context.Context, clientRequestID string) (*RequestSettlement, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	request := s.requestSettlements[clientRequestID]
	if request == nil {
		return nil, ErrNotFound
	}
	return cloneRequestSettlement(request), nil
}

func (s *MemoryStore) GetRequestAttempt(_ context.Context, clientRequestID, providerRequestID string) (*RequestAttempt, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	attempt := s.requestAttempts[settlementAttemptKey(clientRequestID, providerRequestID)]
	if attempt == nil {
		return nil, ErrNotFound
	}
	return cloneRequestAttempt(attempt), nil
}

func (s *MemoryStore) GetAttemptTerminal(_ context.Context, clientRequestID, providerRequestID string) (*AttemptTerminal, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	terminal := s.attemptTerminals[settlementAttemptKey(clientRequestID, providerRequestID)]
	if terminal == nil {
		return nil, ErrNotFound
	}
	return cloneAttemptTerminal(terminal), nil
}

func (s *MemoryStore) ListSettlementEffects(_ context.Context, clientRequestID string) ([]SettlementEffect, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	byID := s.settlementEffects[clientRequestID]
	result := make([]SettlementEffect, 0, len(byID))
	for _, effect := range byID {
		result = append(result, cloneSettlementEffect(effect))
	}
	sort.Slice(result, func(i, j int) bool { return result[i].EffectID < result[j].EffectID })
	return result, nil
}

func (s *MemoryStore) ListRecoverableRequestSettlements(_ context.Context, limit int) ([]RequestSettlement, error) {
	if limit <= 0 {
		limit = 1000
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	result := make([]RequestSettlement, 0)
	for _, request := range s.requestSettlements {
		if request.State == RequestStateSettled || request.State == RequestStateManualReview {
			continue
		}
		result = append(result, *cloneRequestSettlement(request))
	}
	sort.Slice(result, func(i, j int) bool { return result[i].CreatedAt.Before(result[j].CreatedAt) })
	if len(result) > limit {
		result = result[:limit]
	}
	return result, nil
}

var _ SettlementStore = (*MemoryStore)(nil)
