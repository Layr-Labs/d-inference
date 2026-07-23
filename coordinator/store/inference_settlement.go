package store

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

type RequestSettlementState string

const (
	RequestStateReserved         RequestSettlementState = "reserved"
	RequestStateActive           RequestSettlementState = "active"
	RequestStateFenced           RequestSettlementState = "fenced"
	RequestStateTerminalRecorded RequestSettlementState = "terminal_recorded"
	RequestStateDeliveryPending  RequestSettlementState = "delivery_pending"
	RequestStateDeliveryRecorded RequestSettlementState = "delivery_recorded"
	RequestStateSettling         RequestSettlementState = "settling"
	RequestStateSettled          RequestSettlementState = "settled"
	RequestStateManualReview     RequestSettlementState = "manual_review"
)

type AttemptState string

const (
	AttemptStatePendingDispatch AttemptState = "dispatch_pending"
	AttemptStateDispatched      AttemptState = "dispatched"
	AttemptStateTerminal        AttemptState = "terminal"
)

type AttemptDisposition string

const (
	AttemptDispositionActive           AttemptDisposition = "active"
	AttemptDispositionWinner           AttemptDisposition = "winner"
	AttemptDispositionFailedRetry      AttemptDisposition = "failed_retry"
	AttemptDispositionSpeculativeLoser AttemptDisposition = "speculative_loser"
	AttemptDispositionCancelledByFence AttemptDisposition = "cancelled_by_request_fence"
	AttemptDispositionNotApplicable    AttemptDisposition = "not_applicable"
)

type AttemptCancelState string

const (
	AttemptCancelNone         AttemptCancelState = "none"
	AttemptCancelPending      AttemptCancelState = "cancel_pending"
	AttemptCancelOnWire       AttemptCancelState = "on_wire"
	AttemptCancelSendFailed   AttemptCancelState = "send_failed"
	AttemptCancelAcknowledged AttemptCancelState = "acknowledged"
	AttemptCancelGraceExpired AttemptCancelState = "grace_expired"
)

type DeliveryState string

const (
	DeliveryStateNone          DeliveryState = "none"
	DeliveryStatePending       DeliveryState = "pending"
	DeliveryStateConfirmed     DeliveryState = "confirmed"
	DeliveryStateFailed        DeliveryState = "failed"
	DeliveryStateIndeterminate DeliveryState = "indeterminate"
)

type EffectState string

const (
	EffectStatePending       EffectState = "pending"
	EffectStateApplying      EffectState = "applying"
	EffectStateApplied       EffectState = "applied"
	EffectStateNotApplicable EffectState = "not_applicable"
	EffectStateIndeterminate EffectState = "indeterminate"
	EffectStateManualReview  EffectState = "manual_review"
)

type SettlementEffectType string

const (
	EffectBaseReservationDebit SettlementEffectType = "base_reservation_debit"
	EffectServiceHold          SettlementEffectType = "service_hold"
	EffectAttemptExtraDebit    SettlementEffectType = "attempt_extra_debit"
	EffectAttemptExtraRefund   SettlementEffectType = "attempt_extra_refund"
	EffectConsumerCharge       SettlementEffectType = "consumer_charge"
	EffectConsumerAdjustment   SettlementEffectType = "consumer_settle_adjustment"
	EffectConsumerRefund       SettlementEffectType = "consumer_refund"
	EffectProviderPayout       SettlementEffectType = "provider_payout"
	EffectReferralCredit       SettlementEffectType = "referral_credit"
	EffectPlatformFee          SettlementEffectType = "platform_fee"
	EffectExplicitSubsidy      SettlementEffectType = "explicit_subsidy"
	EffectServiceHoldRelease   SettlementEffectType = "service_hold_release"
)

type RequestSettlement struct {
	ClientRequestID         string                 `json:"client_request_id"`
	ConsumerAccountID       string                 `json:"consumer_account_id"`
	KeyID                   string                 `json:"key_id,omitempty"`
	Model                   string                 `json:"model"`
	PublicModel             string                 `json:"public_model,omitempty"`
	Endpoint                string                 `json:"endpoint"`
	Stream                  bool                   `json:"stream"`
	OpenRouterExact         bool                   `json:"openrouter_exact"`
	State                   RequestSettlementState `json:"state"`
	FundingKind             string                 `json:"funding_kind"`
	BaseReservedMicroUSD    int64                  `json:"base_reserved_micro_usd"`
	ReservedMicroUSD        int64                  `json:"reserved_micro_usd"`
	RequestBudgetMS         int64                  `json:"request_budget_ms"`
	WinnerAttemptID         string                 `json:"winner_attempt_id,omitempty"`
	WinnerEpoch             int64                  `json:"winner_epoch"`
	WinnerIngressSequence   uint64                 `json:"winner_ingress_sequence"`
	FenceCause              string                 `json:"fence_cause,omitempty"`
	FenceVersion            int                    `json:"fence_version"`
	FenceSequence           uint64                 `json:"fence_sequence,omitempty"`
	LastIngressSequence     uint64                 `json:"last_ingress_sequence"`
	TransportState          string                 `json:"transport_state"`
	ProtocolState           string                 `json:"protocol_state"`
	SemanticState           string                 `json:"semantic_state"`
	WrittenIngressSequence  uint64                 `json:"written_ingress_sequence"`
	WrittenChunkSequence    uint64                 `json:"written_chunk_sequence"`
	WrittenCompletionTokens int                    `json:"written_completion_tokens"`
	WrittenCommitment       string                 `json:"written_commitment,omitempty"`
	DeliveryState           DeliveryState          `json:"delivery_state"`
	ClientSnapshotHash      string                 `json:"client_snapshot_hash,omitempty"`
	ClientSnapshot          CanonicalSnapshot      `json:"client_snapshot,omitempty"`
	SettlementSnapshotHash  string                 `json:"settlement_snapshot_hash,omitempty"`
	SettlementSnapshot      CanonicalSnapshot      `json:"settlement_snapshot,omitempty"`
	EffectsSealed           bool                   `json:"effects_sealed"`
	StartedAt               time.Time              `json:"started_at"`
	CreatedAt               time.Time              `json:"created_at"`
	UpdatedAt               time.Time              `json:"updated_at"`
}

type RequestAttempt struct {
	ClientRequestID   string             `json:"client_request_id"`
	ProviderRequestID string             `json:"provider_request_id"`
	ProviderID        string             `json:"provider_id"`
	Attempt           int                `json:"attempt"`
	Role              string             `json:"role"`
	State             AttemptState       `json:"state"`
	Disposition       AttemptDisposition `json:"disposition"`
	WinnerEpoch       int64              `json:"winner_epoch"`
	ProtocolVersion   int                `json:"protocol_version"`
	BudgetMS          int64              `json:"budget_ms"`
	AdmissionState    string             `json:"admission_state"`
	TopUpMicroUSD     int64              `json:"top_up_micro_usd"`
	CancelState       AttemptCancelState `json:"cancel_state"`
	CancelReason      string             `json:"cancel_reason,omitempty"`
	FenceVersion      int                `json:"fence_version"`
	FenceSequence     uint64             `json:"fence_sequence"`
	DispatchedAt      *time.Time         `json:"dispatched_at,omitempty"`
	CreatedAt         time.Time          `json:"created_at"`
	UpdatedAt         time.Time          `json:"updated_at"`
}

type AttemptTerminal struct {
	ClientRequestID      string            `json:"client_request_id"`
	ProviderRequestID    string            `json:"provider_request_id"`
	IngressSequence      uint64            `json:"ingress_sequence"`
	SnapshotHash         string            `json:"snapshot_hash"`
	Snapshot             CanonicalSnapshot `json:"snapshot"`
	MetadataVersion      int               `json:"metadata_version"`
	Envelope             string            `json:"envelope"`
	Kind                 string            `json:"kind"`
	Cause                string            `json:"cause"`
	Stage                string            `json:"stage"`
	Source               string            `json:"source"`
	AdmissionState       string            `json:"admission_state"`
	PromptTokens         int               `json:"prompt_tokens"`
	CompletionTokens     int               `json:"completion_tokens"`
	ReasoningTokens      int               `json:"reasoning_tokens"`
	LastChunkSequence    uint64            `json:"last_chunk_sequence"`
	LastCompletionTokens int               `json:"last_completion_tokens"`
	TerminationReason    string            `json:"termination_reason,omitempty"`
	RequestFenceVersion  int               `json:"request_fence_version"`
	RequestFenceSequence uint64            `json:"request_fence_sequence"`
	CancelReason         string            `json:"cancel_reason,omitempty"`
	ResponseHash         string            `json:"response_hash,omitempty"`
	TranscriptHash       string            `json:"transcript_hash,omitempty"`
	TerminalHash         string            `json:"terminal_hash,omitempty"`
	TerminalSignature    string            `json:"terminal_signature,omitempty"`
	EvidenceValid        bool              `json:"evidence_valid"`
	HealthOutcome        string            `json:"health_outcome"`
	CreatedAt            time.Time         `json:"created_at"`
}

type SettlementEffect struct {
	EffectID          string               `json:"effect_id"`
	ClientRequestID   string               `json:"client_request_id"`
	ProviderRequestID string               `json:"provider_request_id,omitempty"`
	Type              SettlementEffectType `json:"effect_type"`
	TargetKind        string               `json:"target_kind,omitempty"`
	Beneficiary       string               `json:"beneficiary,omitempty"`
	IdempotencyKey    string               `json:"idempotency_key"`
	AmountMicroUSD    int64                `json:"amount_micro_usd"`
	DependsOn         []string             `json:"depends_on,omitempty"`
	Payload           json.RawMessage      `json:"payload,omitempty"`
	SealedPlan        bool                 `json:"sealed_plan"`
	State             EffectState          `json:"state"`
	LastError         string               `json:"last_error,omitempty"`
	ApplyAttempts     int                  `json:"apply_attempts"`
	ClaimOwner        string               `json:"claim_owner,omitempty"`
	ClaimExpiresAt    *time.Time           `json:"claim_expires_at,omitempty"`
	CreatedAt         time.Time            `json:"created_at"`
	UpdatedAt         time.Time            `json:"updated_at"`
}

type BeginRequestReservationParams struct {
	Request          RequestSettlement
	ServiceHold      bool
	KeyLimitMicroUSD *int64
	KeySpendSince    time.Time
}

type BeginAttemptParams struct {
	Attempt          RequestAttempt
	KeyLimitMicroUSD *int64
	KeySpendSince    time.Time
}

type WinnerSelection struct {
	ClientRequestID   string
	ProviderRequestID string
	ExpectedEpoch     int64
	IngressSequence   uint64
}

type RequestFence struct {
	ClientRequestID string
	Cause           string
	Sequence        uint64
	FenceVersion    int
	AttemptIDs      []string
}

type AttemptCancelTransition struct {
	ClientRequestID   string
	ProviderRequestID string
	FenceVersion      int
	FenceSequence     uint64
	From              AttemptCancelState
	To                AttemptCancelState
}

type AttemptTerminalClaim struct {
	Terminal    AttemptTerminal
	EmptyWinner *WinnerSelection
}

type DeliveryCheckpoint struct {
	ClientRequestID         string
	ProviderRequestID       string
	IngressSequence         uint64
	TransportState          string
	ProtocolState           string
	SemanticState           string
	WrittenChunkSequence    uint64
	WrittenCompletionTokens int
	WrittenCommitment       string
}

type ClaimSettlementEffectParams struct {
	WorkerID string
	Now      time.Time
	Lease    time.Duration
}

type CompleteSettlementEffectParams struct {
	EffectID       string
	IdempotencyKey string
	WorkerID       string
	State          EffectState
	LastError      string
}

type SettlementStore interface {
	BeginRequestReservation(context.Context, BeginRequestReservationParams) (*RequestSettlement, bool, error)
	BeginAttemptBeforeDispatch(context.Context, BeginAttemptParams) (*RequestAttempt, bool, error)
	MarkAttemptDispatched(context.Context, string, string, time.Time) error
	AdvanceAttemptAdmission(context.Context, string, string, string) error
	SelectRequestWinner(context.Context, WinnerSelection) (*RequestSettlement, bool, error)
	ReleaseRequestWinnerForRetry(context.Context, string, string, int64) (*RequestSettlement, bool, error)
	FenceRequest(context.Context, RequestFence) (*RequestSettlement, bool, error)
	TransitionAttemptCancel(context.Context, AttemptCancelTransition) (bool, error)
	ClaimAttemptTerminal(context.Context, AttemptTerminalClaim) (*AttemptTerminal, bool, error)
	AdvanceDeliveryCheckpoint(context.Context, DeliveryCheckpoint) (*RequestSettlement, bool, error)
	RecordDeliveryResult(context.Context, string, string, DeliveryState, json.RawMessage) (*RequestSettlement, bool, error)
	SealSettlementEffects(context.Context, string, string, string, json.RawMessage, []SettlementEffect) (*RequestSettlement, bool, error)
	ClaimReadySettlementEffect(context.Context, ClaimSettlementEffectParams) (*SettlementEffect, error)
	CompleteSettlementEffect(context.Context, CompleteSettlementEffectParams) (*SettlementEffect, bool, error)
	GetRequestSettlement(context.Context, string) (*RequestSettlement, error)
	GetRequestAttempt(context.Context, string, string) (*RequestAttempt, error)
	GetAttemptTerminal(context.Context, string, string) (*AttemptTerminal, error)
	ListSettlementEffects(context.Context, string) ([]SettlementEffect, error)
	ListRecoverableRequestSettlements(context.Context, int) ([]RequestSettlement, error)
}

// CanonicalSnapshot preserves the exact bytes whose SHA-256 is stored beside a
// terminal, delivery, or settlement snapshot. PostgreSQL's to_jsonb renders a
// BYTEA column as a string; UnmarshalJSON accepts that representation as well as
// ordinary raw JSON so both store implementations expose identical bytes.
type CanonicalSnapshot []byte

func (s CanonicalSnapshot) MarshalJSON() ([]byte, error) {
	if len(s) == 0 {
		return []byte("null"), nil
	}
	if !json.Valid(s) {
		return nil, fmt.Errorf("canonical snapshot is not valid JSON")
	}
	return append([]byte(nil), s...), nil
}

func (s *CanonicalSnapshot) UnmarshalJSON(data []byte) error {
	if string(data) == "null" {
		*s = nil
		return nil
	}
	if len(data) > 0 && data[0] == '"' {
		var encoded string
		if err := json.Unmarshal(data, &encoded); err != nil {
			return err
		}
		var decoded []byte
		var err error
		if strings.HasPrefix(encoded, `\x`) {
			decoded, err = hex.DecodeString(encoded[2:])
		} else {
			decoded, err = base64.StdEncoding.DecodeString(encoded)
		}
		if err != nil {
			return fmt.Errorf("decode canonical snapshot bytes: %w", err)
		}
		if !json.Valid(decoded) {
			return fmt.Errorf("canonical snapshot bytes are not valid JSON")
		}
		*s = append((*s)[:0], decoded...)
		return nil
	}
	if !json.Valid(data) {
		return fmt.Errorf("canonical snapshot is not valid JSON")
	}
	*s = append((*s)[:0], data...)
	return nil
}

func HashSettlementSnapshot(snapshot []byte) string {
	sum := sha256.Sum256(snapshot)
	return hex.EncodeToString(sum[:])
}

func validSettlementSnapshot(snapshot []byte, hash string) bool {
	return len(snapshot) > 0 && json.Valid(snapshot) && hash == HashSettlementSnapshot(snapshot)
}

func validCancelTransition(from, to AttemptCancelState) bool {
	switch from {
	case AttemptCancelPending:
		return to == AttemptCancelOnWire || to == AttemptCancelSendFailed || to == AttemptCancelAcknowledged || to == AttemptCancelGraceExpired
	case AttemptCancelSendFailed:
		return to == AttemptCancelOnWire || to == AttemptCancelAcknowledged || to == AttemptCancelGraceExpired
	case AttemptCancelOnWire:
		return to == AttemptCancelAcknowledged || to == AttemptCancelGraceExpired
	default:
		return false
	}
}

func deliveryStateRank(value, zero, one, two string) int {
	if value == zero {
		return 0
	}
	if value == one {
		return 1
	}
	if two != "" && value == two {
		return 2
	}
	return -1
}

func validLowerHexDigest(value string) bool {
	if len(value) != sha256.Size*2 || strings.ToLower(value) != value {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}

func validateAttemptCreation(existing []RequestAttempt, attempt RequestAttempt) error {
	if attempt.Role != "primary" && attempt.Role != "backup" {
		return ErrInvalidTransition
	}
	if attempt.Role == "backup" {
		for _, current := range existing {
			if current.Attempt == attempt.Attempt && current.Role == "primary" &&
				current.State != AttemptStateTerminal && current.Disposition == AttemptDispositionActive {
				return nil
			}
		}
		return ErrInvalidTransition
	}
	if attempt.Attempt == 0 {
		if len(existing) == 0 {
			return nil
		}
		return ErrInvalidTransition
	}
	previousPrimary := false
	for _, current := range existing {
		if current.Attempt >= attempt.Attempt {
			return ErrInvalidTransition
		}
		if current.State != AttemptStateTerminal {
			return ErrInvalidTransition
		}
		if current.Attempt == attempt.Attempt-1 && current.Role == "primary" {
			previousPrimary = true
		}
	}
	if !previousPrimary {
		return ErrInvalidTransition
	}
	return nil
}

func checkedAddMicroUSD(total, amount int64) (int64, bool) {
	if amount < 0 || total > int64(^uint64(0)>>1)-amount {
		return 0, false
	}
	return total + amount, true
}

func validateSettlementEffectPlan(request *RequestSettlement, attempts []RequestAttempt, existing, planned []SettlementEffect) error {
	if request == nil {
		return ErrInvalidTransition
	}
	all := make(map[string]SettlementEffect, len(existing)+len(planned))
	keys := make(map[string]string, len(existing)+len(planned))
	for _, effect := range existing {
		if effect.EffectID == "" || effect.IdempotencyKey == "" || effect.AmountMicroUSD < 0 {
			return ErrInvalidTransition
		}
		if priorID, ok := keys[effect.IdempotencyKey]; ok && priorID != effect.EffectID {
			return ErrConflict
		}
		all[effect.EffectID] = effect
		keys[effect.IdempotencyKey] = effect.EffectID
	}
	for _, effect := range planned {
		if effect.EffectID == "" || effect.IdempotencyKey == "" || effect.ClientRequestID != request.ClientRequestID || effect.AmountMicroUSD < 0 {
			return ErrInvalidTransition
		}
		if _, ok := all[effect.EffectID]; ok {
			return ErrConflict
		}
		if _, ok := keys[effect.IdempotencyKey]; ok {
			return ErrConflict
		}
		if effect.State != "" && effect.State != EffectStatePending && effect.State != EffectStateNotApplicable {
			return ErrInvalidTransition
		}
		all[effect.EffectID] = effect
		keys[effect.IdempotencyKey] = effect.EffectID
	}
	attemptByID := make(map[string]RequestAttempt, len(attempts))
	for _, attempt := range attempts {
		attemptByID[attempt.ProviderRequestID] = attempt
	}
	var charge, subsidy, payout int64
	for _, effect := range all {
		var ok bool
		switch effect.Type {
		case EffectConsumerCharge:
			charge, ok = checkedAddMicroUSD(charge, effect.AmountMicroUSD)
		case EffectExplicitSubsidy:
			subsidy, ok = checkedAddMicroUSD(subsidy, effect.AmountMicroUSD)
		case EffectProviderPayout:
			payout, ok = checkedAddMicroUSD(payout, effect.AmountMicroUSD)
		default:
			ok = true
		}
		if !ok {
			return ErrInvalidTransition
		}
		if effect.ProviderRequestID != "" {
			attempt, exists := attemptByID[effect.ProviderRequestID]
			if !exists {
				return ErrInvalidTransition
			}
			if effect.Type == EffectProviderPayout && (attempt.Disposition != AttemptDispositionWinner || effect.ProviderRequestID != request.WinnerAttemptID) {
				return ErrInvalidTransition
			}
		}
		if effect.Type == EffectProviderPayout {
			if effect.ProviderRequestID == "" || effect.Beneficiary == "" || (effect.TargetKind != "account" && effect.TargetKind != "wallet") {
				return ErrInvalidTransition
			}
		}
		for _, dependency := range effect.DependsOn {
			if dependency == effect.EffectID {
				return ErrInvalidTransition
			}
			if _, ok := all[dependency]; !ok {
				return ErrInvalidTransition
			}
		}
		if effect.Type == EffectProviderPayout || effect.Type == EffectReferralCredit || effect.Type == EffectPlatformFee {
			funded := false
			for _, dependency := range effect.DependsOn {
				depType := all[dependency].Type
				if depType == EffectConsumerCharge || depType == EffectExplicitSubsidy {
					funded = true
					break
				}
			}
			if !funded && effect.AmountMicroUSD > 0 {
				return ErrInvalidTransition
			}
		}
	}
	funding, ok := checkedAddMicroUSD(charge, subsidy)
	if !ok || charge > request.ReservedMicroUSD || payout > funding {
		return ErrInvalidTransition
	}
	visiting := make(map[string]bool, len(all))
	visited := make(map[string]bool, len(all))
	var visit func(string) bool
	visit = func(id string) bool {
		if visiting[id] {
			return false
		}
		if visited[id] {
			return true
		}
		visiting[id] = true
		for _, dependency := range all[id].DependsOn {
			if !visit(dependency) {
				return false
			}
		}
		delete(visiting, id)
		visited[id] = true
		return true
	}
	for id := range all {
		if !visit(id) {
			return ErrInvalidTransition
		}
	}
	return nil
}

func sameSettlementEffectDefinition(a, b SettlementEffect) bool {
	if a.EffectID != b.EffectID || a.ClientRequestID != b.ClientRequestID ||
		a.ProviderRequestID != b.ProviderRequestID || a.Type != b.Type || a.TargetKind != b.TargetKind ||
		a.Beneficiary != b.Beneficiary || a.IdempotencyKey != b.IdempotencyKey || a.AmountMicroUSD != b.AmountMicroUSD ||
		normalizedEffectPayload(a.Payload) != normalizedEffectPayload(b.Payload) || len(a.DependsOn) != len(b.DependsOn) {
		return false
	}
	for i := range a.DependsOn {
		if a.DependsOn[i] != b.DependsOn[i] {
			return false
		}
	}
	return true
}

func normalizedEffectPayload(payload json.RawMessage) string {
	if len(payload) == 0 || string(payload) == "null" {
		return ""
	}
	return string(payload)
}

func sameSealedEffectPlan(existing, planned []SettlementEffect) bool {
	stored := make(map[string]SettlementEffect)
	for _, effect := range existing {
		if effect.SealedPlan {
			stored[effect.EffectID] = effect
		}
	}
	if len(stored) != len(planned) {
		return false
	}
	for _, effect := range planned {
		prior, ok := stored[effect.EffectID]
		if !ok || !sameSettlementEffectDefinition(prior, effect) {
			return false
		}
	}
	return true
}
