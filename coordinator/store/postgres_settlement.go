package store

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"time"

	"github.com/jackc/pgx/v5"
)

const settlementStoreTimeout = 5 * time.Second

type settlementRowScanner interface {
	Scan(...any) error
}

func scanSettlementJSON[T any](row settlementRowScanner) (*T, error) {
	var raw []byte
	if err := row.Scan(&raw); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	var value T
	if err := json.Unmarshal(raw, &value); err != nil {
		return nil, fmt.Errorf("decode settlement row: %w", err)
	}
	return &value, nil
}

func settlementUint64(value uint64) (int64, error) {
	if value > math.MaxInt64 {
		return 0, ErrInvalidTransition
	}
	return int64(value), nil
}

func settlementContext(parent context.Context) (context.Context, context.CancelFunc) {
	if parent == nil {
		parent = context.Background()
	}
	return context.WithTimeout(parent, settlementStoreTimeout)
}

func debitSettlementPostgresTx(ctx context.Context, tx pgx.Tx, accountID string, amount int64, reference string) error {
	if amount < 0 {
		return ErrInvalidTransition
	}
	var balanceAfter int64
	err := tx.QueryRow(ctx, `
		WITH debit AS (
			UPDATE balances
			SET balance_micro_usd = balance_micro_usd - $2,
			    withdrawable_micro_usd = LEAST(withdrawable_micro_usd, balance_micro_usd - $2),
			    updated_at = NOW()
			WHERE account_id = $1 AND balance_micro_usd >= $2
			RETURNING balance_micro_usd
		), ledger AS (
			INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
			SELECT $1, $3, -$2, balance_micro_usd, $4 FROM debit
		)
		SELECT balance_micro_usd FROM debit`,
		accountID, amount, string(LedgerCharge), reference).Scan(&balanceAfter)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrInsufficientBalance
	}
	if err != nil {
		return fmt.Errorf("settlement debit: %w", err)
	}
	return nil
}

func getRequestSettlementTx(ctx context.Context, tx pgx.Tx, id string, forUpdate bool) (*RequestSettlement, error) {
	query := `SELECT to_jsonb(r) FROM request_settlements r WHERE client_request_id = $1`
	if forUpdate {
		query += ` FOR UPDATE`
	}
	return scanSettlementJSON[RequestSettlement](tx.QueryRow(ctx, query, id))
}

func getRequestAttemptTx(ctx context.Context, tx pgx.Tx, clientID, providerID string, forUpdate bool) (*RequestAttempt, error) {
	query := `SELECT to_jsonb(a) FROM request_attempts a WHERE client_request_id = $1 AND provider_request_id = $2`
	if forUpdate {
		query += ` FOR UPDATE`
	}
	return scanSettlementJSON[RequestAttempt](tx.QueryRow(ctx, query, clientID, providerID))
}

func getAttemptTerminalTx(ctx context.Context, tx pgx.Tx, clientID, providerID string) (*AttemptTerminal, error) {
	return scanSettlementJSON[AttemptTerminal](tx.QueryRow(ctx,
		`SELECT to_jsonb(t) FROM attempt_terminals t WHERE client_request_id = $1 AND provider_request_id = $2`,
		clientID, providerID))
}

func listSettlementEffectsTx(ctx context.Context, tx pgx.Tx, clientID string) ([]SettlementEffect, error) {
	rows, err := tx.Query(ctx, `SELECT to_jsonb(e) FROM settlement_effects e WHERE client_request_id = $1 ORDER BY effect_id`, clientID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]SettlementEffect, 0)
	for rows.Next() {
		effect, err := scanSettlementJSON[SettlementEffect](rows)
		if err != nil {
			return nil, err
		}
		result = append(result, *effect)
	}
	return result, rows.Err()
}

func getSettlementEffectTx(ctx context.Context, tx pgx.Tx, effectID string, forUpdate bool) (*SettlementEffect, error) {
	query := `SELECT to_jsonb(e) FROM settlement_effects e WHERE effect_id = $1`
	if forUpdate {
		query += ` FOR UPDATE`
	}
	return scanSettlementJSON[SettlementEffect](tx.QueryRow(ctx, query, effectID))
}

func listRequestAttemptsTx(ctx context.Context, tx pgx.Tx, clientID string) ([]RequestAttempt, error) {
	rows, err := tx.Query(ctx, `SELECT to_jsonb(a) FROM request_attempts a WHERE client_request_id = $1 ORDER BY attempt, role`, clientID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]RequestAttempt, 0)
	for rows.Next() {
		attempt, err := scanSettlementJSON[RequestAttempt](rows)
		if err != nil {
			return nil, err
		}
		result = append(result, *attempt)
	}
	return result, rows.Err()
}

func nullableJSONRaw(value json.RawMessage) any {
	if len(value) == 0 {
		return nil
	}
	return string(value)
}

func lockSettlementKey(ctx context.Context, tx pgx.Tx, key string) error {
	_, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, key)
	return err
}

func (s *PostgresStore) BeginRequestReservation(parent context.Context, params BeginRequestReservationParams) (*RequestSettlement, bool, error) {
	request := params.Request
	if request.ClientRequestID == "" || request.ConsumerAccountID == "" || request.Model == "" || request.Endpoint == "" ||
		request.ReservedMicroUSD < 0 || request.RequestBudgetMS <= 0 || request.StartedAt.IsZero() {
		return nil, false, ErrInvalidTransition
	}
	request.StartedAt = request.StartedAt.UTC().Truncate(time.Microsecond)
	if params.ServiceHold {
		request.FundingKind = "service_hold"
	} else {
		request.FundingKind = "ledger"
	}
	request.BaseReservedMicroUSD = request.ReservedMicroUSD
	ctx, cancel := settlementContext(parent)
	defer cancel()
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return nil, false, err
	}
	defer tx.Rollback(ctx)
	if err := lockSettlementKey(ctx, tx, "request:"+request.ClientRequestID); err != nil {
		return nil, false, err
	}
	if existing, err := getRequestSettlementTx(ctx, tx, request.ClientRequestID, true); err == nil {
		if !sameRequestReservation(existing, &request) {
			return nil, false, ErrConflict
		}
		return existing, false, tx.Commit(ctx)
	} else if !errors.Is(err, ErrNotFound) {
		return nil, false, err
	}

	if request.KeyID != "" && params.KeyLimitMicroUSD != nil {
		if err := lockSettlementKey(ctx, tx, "key-hold:"+request.KeyID); err != nil {
			return nil, false, err
		}
		var settled, active int64
		if err := tx.QueryRow(ctx, `SELECT COALESCE(SUM(cost_micro_usd), 0) FROM usage WHERE key_id = $1 AND ($2::timestamptz IS NULL OR created_at >= $2)`,
			request.KeyID, nullableTime(params.KeySpendSince)).Scan(&settled); err != nil {
			return nil, false, err
		}
		if err := tx.QueryRow(ctx, `SELECT COALESCE(SUM(reserved_micro_usd), 0) FROM request_settlements
			WHERE key_id = $1 AND state <> 'settled'
			  AND ($2::timestamptz IS NULL OR started_at >= $2)`,
			request.KeyID, nullableTime(params.KeySpendSince)).Scan(&active); err != nil {
			return nil, false, err
		}
		if request.ReservedMicroUSD > *params.KeyLimitMicroUSD-settled-active {
			return nil, false, ErrInsufficientBalance
		}
	}

	if params.ServiceHold {
		if err := lockSettlementKey(ctx, tx, "service-hold:"+request.ConsumerAccountID); err != nil {
			return nil, false, err
		}
		var balance, held int64
		if err := tx.QueryRow(ctx, `SELECT balance_micro_usd FROM balances WHERE account_id = $1 FOR UPDATE`, request.ConsumerAccountID).Scan(&balance); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, false, ErrInsufficientBalance
			}
			return nil, false, err
		}
		if err := tx.QueryRow(ctx, `SELECT COALESCE(SUM(reserved_micro_usd), 0) FROM request_settlements
			WHERE consumer_account_id = $1 AND funding_kind = 'service_hold'
			  AND state <> 'settled'`, request.ConsumerAccountID).Scan(&held); err != nil {
			return nil, false, err
		}
		if balance-held < request.ReservedMicroUSD {
			return nil, false, ErrInsufficientBalance
		}
	} else if err := debitSettlementPostgresTx(ctx, tx, request.ConsumerAccountID, request.ReservedMicroUSD,
		"settlement:"+request.ClientRequestID+":base"); err != nil {
		return nil, false, err
	}

	now := time.Now().UTC()
	request.State = RequestStateReserved
	request.TransportState = "T0"
	request.ProtocolState = "V0"
	request.SemanticState = "C0"
	request.DeliveryState = DeliveryStateNone
	_, err = tx.Exec(ctx, `INSERT INTO request_settlements (
		client_request_id, consumer_account_id, key_id, model, public_model, endpoint, stream,
		openrouter_exact, state, funding_kind, base_reserved_micro_usd, reserved_micro_usd,
		request_budget_ms, winner_epoch, transport_state, protocol_state, semantic_state,
		delivery_state, effects_sealed, started_at, created_at, updated_at
	) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,0,'T0','V0','C0',$14,FALSE,$15,$16,$16)`,
		request.ClientRequestID, request.ConsumerAccountID, request.KeyID, request.Model, request.PublicModel,
		request.Endpoint, request.Stream, request.OpenRouterExact, string(request.State), request.FundingKind,
		request.BaseReservedMicroUSD, request.ReservedMicroUSD, request.RequestBudgetMS,
		string(request.DeliveryState), request.StartedAt, now)
	if err != nil {
		return nil, false, fmt.Errorf("insert request settlement: %w", err)
	}
	effectType := EffectBaseReservationDebit
	if params.ServiceHold {
		effectType = EffectServiceHold
	}
	_, err = tx.Exec(ctx, `INSERT INTO settlement_effects (
		effect_id, client_request_id, effect_type, beneficiary, idempotency_key,
		amount_micro_usd, state, created_at, updated_at
	) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$8)`,
		request.ClientRequestID+":base", request.ClientRequestID, string(effectType), request.ConsumerAccountID,
		request.ClientRequestID+":"+string(effectType), request.ReservedMicroUSD, string(EffectStateApplied), now)
	if err != nil {
		return nil, false, fmt.Errorf("insert base settlement effect: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, false, err
	}
	created, err := s.GetRequestSettlement(parent, request.ClientRequestID)
	return created, true, err
}

func nullableTime(value time.Time) any {
	if value.IsZero() {
		return nil
	}
	return value
}

func (s *PostgresStore) BeginAttemptBeforeDispatch(parent context.Context, params BeginAttemptParams) (*RequestAttempt, bool, error) {
	attempt := params.Attempt
	if attempt.ClientRequestID == "" || attempt.ProviderRequestID == "" || attempt.ProviderID == "" ||
		attempt.Attempt < 0 || attempt.ProtocolVersion < 0 || attempt.BudgetMS < 0 || attempt.TopUpMicroUSD < 0 {
		return nil, false, ErrInvalidTransition
	}
	if attempt.Role == "" {
		attempt.Role = "primary"
	}
	ctx, cancel := settlementContext(parent)
	defer cancel()
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return nil, false, err
	}
	defer tx.Rollback(ctx)
	if err := lockSettlementKey(ctx, tx, "attempt:"+attempt.ProviderRequestID); err != nil {
		return nil, false, err
	}
	if existing, err := getRequestAttemptTx(ctx, tx, attempt.ClientRequestID, attempt.ProviderRequestID, true); err == nil {
		if !sameAttemptIdentity(existing, &attempt) {
			return nil, false, ErrConflict
		}
		return existing, false, tx.Commit(ctx)
	} else if !errors.Is(err, ErrNotFound) {
		return nil, false, err
	}
	request, err := getRequestSettlementTx(ctx, tx, attempt.ClientRequestID, true)
	if err != nil {
		return nil, false, err
	}
	if (request.State != RequestStateReserved && request.State != RequestStateActive) || request.FenceCause != "" ||
		request.WinnerAttemptID != "" || request.DeliveryState != DeliveryStateNone || request.EffectsSealed {
		return nil, false, ErrInvalidTransition
	}
	var duplicateRole bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM request_attempts WHERE client_request_id = $1 AND attempt = $2 AND role = $3)`,
		attempt.ClientRequestID, attempt.Attempt, attempt.Role).Scan(&duplicateRole); err != nil {
		return nil, false, err
	}
	if duplicateRole {
		return nil, false, ErrConflict
	}
	existingAttempts, err := listRequestAttemptsTx(ctx, tx, attempt.ClientRequestID)
	if err != nil {
		return nil, false, err
	}
	if err := validateAttemptCreation(existingAttempts, attempt); err != nil {
		return nil, false, err
	}
	if attempt.TopUpMicroUSD > 0 {
		if request.KeyID != "" && params.KeyLimitMicroUSD != nil {
			if err := lockSettlementKey(ctx, tx, "key-hold:"+request.KeyID); err != nil {
				return nil, false, err
			}
			var settled, active int64
			if err := tx.QueryRow(ctx, `SELECT COALESCE(SUM(cost_micro_usd), 0) FROM usage WHERE key_id = $1 AND ($2::timestamptz IS NULL OR created_at >= $2)`,
				request.KeyID, nullableTime(params.KeySpendSince)).Scan(&settled); err != nil {
				return nil, false, err
			}
			if err := tx.QueryRow(ctx, `SELECT COALESCE(SUM(reserved_micro_usd), 0) FROM request_settlements
				WHERE key_id = $1 AND state <> 'settled'
				  AND ($2::timestamptz IS NULL OR started_at >= $2)`,
				request.KeyID, nullableTime(params.KeySpendSince)).Scan(&active); err != nil {
				return nil, false, err
			}
			if attempt.TopUpMicroUSD > *params.KeyLimitMicroUSD-settled-active {
				return nil, false, ErrInsufficientBalance
			}
		}
		if request.FundingKind == "service_hold" {
			if err := lockSettlementKey(ctx, tx, "service-hold:"+request.ConsumerAccountID); err != nil {
				return nil, false, err
			}
			var balance, held int64
			if err := tx.QueryRow(ctx, `SELECT balance_micro_usd FROM balances WHERE account_id = $1 FOR UPDATE`, request.ConsumerAccountID).Scan(&balance); err != nil {
				if errors.Is(err, pgx.ErrNoRows) {
					return nil, false, ErrInsufficientBalance
				}
				return nil, false, err
			}
			if err := tx.QueryRow(ctx, `SELECT COALESCE(SUM(reserved_micro_usd), 0) FROM request_settlements
				WHERE consumer_account_id = $1 AND funding_kind = 'service_hold'
				  AND state <> 'settled'`, request.ConsumerAccountID).Scan(&held); err != nil {
				return nil, false, err
			}
			if balance-held < attempt.TopUpMicroUSD {
				return nil, false, ErrInsufficientBalance
			}
		} else if err := debitSettlementPostgresTx(ctx, tx, request.ConsumerAccountID, attempt.TopUpMicroUSD,
			"settlement:"+attempt.ClientRequestID+":"+attempt.ProviderRequestID+":topup"); err != nil {
			return nil, false, err
		}
		if _, err := tx.Exec(ctx, `UPDATE request_settlements SET reserved_micro_usd = reserved_micro_usd + $2, updated_at = NOW() WHERE client_request_id = $1`,
			attempt.ClientRequestID, attempt.TopUpMicroUSD); err != nil {
			return nil, false, err
		}
		now := time.Now().UTC()
		_, err = tx.Exec(ctx, `INSERT INTO settlement_effects (
			effect_id, client_request_id, provider_request_id, effect_type, beneficiary,
			idempotency_key, amount_micro_usd, state, created_at, updated_at
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$9)`,
			attempt.ClientRequestID+":"+attempt.ProviderRequestID+":topup", attempt.ClientRequestID,
			attempt.ProviderRequestID, string(EffectAttemptExtraDebit), request.ConsumerAccountID,
			attempt.ClientRequestID+":"+attempt.ProviderRequestID+":"+string(EffectAttemptExtraDebit),
			attempt.TopUpMicroUSD, string(EffectStateApplied), now)
		if err != nil {
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
	_, err = tx.Exec(ctx, `INSERT INTO request_attempts (
		client_request_id, provider_request_id, provider_id, attempt, role, state, disposition,
		winner_epoch, protocol_version, budget_ms, admission_state, top_up_micro_usd,
		cancel_state, created_at, updated_at
	) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$14)`,
		attempt.ClientRequestID, attempt.ProviderRequestID, attempt.ProviderID, attempt.Attempt,
		attempt.Role, string(attempt.State), string(attempt.Disposition), attempt.WinnerEpoch,
		attempt.ProtocolVersion, attempt.BudgetMS, attempt.AdmissionState, attempt.TopUpMicroUSD,
		string(attempt.CancelState), now)
	if err != nil {
		return nil, false, fmt.Errorf("insert request attempt: %w", err)
	}
	if _, err := tx.Exec(ctx, `UPDATE request_settlements SET state = $2, updated_at = $3 WHERE client_request_id = $1`,
		attempt.ClientRequestID, string(RequestStateActive), now); err != nil {
		return nil, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, false, err
	}
	created, err := s.GetRequestAttempt(parent, attempt.ClientRequestID, attempt.ProviderRequestID)
	return created, true, err
}

func (s *PostgresStore) MarkAttemptDispatched(parent context.Context, clientID, providerID string, at time.Time) error {
	if at.IsZero() {
		at = time.Now().UTC()
	}
	ctx, cancel := settlementContext(parent)
	defer cancel()
	command, err := s.pool.Exec(ctx, `UPDATE request_attempts SET state = $3, dispatched_at = $4, updated_at = NOW()
		WHERE client_request_id = $1 AND provider_request_id = $2 AND state = $5`,
		clientID, providerID, string(AttemptStateDispatched), at, string(AttemptStatePendingDispatch))
	if err != nil {
		return err
	}
	if command.RowsAffected() == 1 {
		return nil
	}
	attempt, err := s.GetRequestAttempt(parent, clientID, providerID)
	if err == nil && attempt.State == AttemptStateDispatched {
		return nil
	}
	if err != nil {
		return err
	}
	return ErrInvalidTransition
}

func (s *PostgresStore) AdvanceAttemptAdmission(parent context.Context, clientID, providerID, state string) error {
	rank := admissionRank(state)
	if rank < 0 {
		return ErrInvalidTransition
	}
	ctx, cancel := settlementContext(parent)
	defer cancel()
	command, err := s.pool.Exec(ctx, `UPDATE request_attempts SET admission_state = $3, updated_at = NOW()
		WHERE client_request_id = $1 AND provider_request_id = $2
		  AND state <> $5
		  AND CASE admission_state WHEN 'pre_accept' THEN 0 WHEN 'accepted' THEN 1 WHEN 'running' THEN 2 ELSE -1 END <= $4`,
		clientID, providerID, state, rank, string(AttemptStateTerminal))
	if err != nil {
		return err
	}
	if command.RowsAffected() == 0 {
		return ErrInvalidTransition
	}
	return nil
}

func (s *PostgresStore) SelectRequestWinner(parent context.Context, selection WinnerSelection) (*RequestSettlement, bool, error) {
	ingress, err := settlementUint64(selection.IngressSequence)
	if err != nil || selection.ClientRequestID == "" || selection.ProviderRequestID == "" || ingress == 0 {
		return nil, false, ErrInvalidTransition
	}
	ctx, cancel := settlementContext(parent)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, false, err
	}
	defer tx.Rollback(ctx)
	request, err := getRequestSettlementTx(ctx, tx, selection.ClientRequestID, true)
	if err != nil {
		return nil, false, err
	}
	if request.WinnerAttemptID != "" {
		if request.WinnerAttemptID == selection.ProviderRequestID && request.WinnerEpoch == selection.ExpectedEpoch &&
			request.WinnerIngressSequence == selection.IngressSequence {
			return request, false, tx.Commit(ctx)
		}
		return nil, false, ErrConflict
	}
	if request.WinnerEpoch != selection.ExpectedEpoch || request.FenceCause != "" || request.EffectsSealed ||
		selection.IngressSequence <= request.LastIngressSequence {
		return nil, false, ErrInvalidTransition
	}
	winner, err := getRequestAttemptTx(ctx, tx, selection.ClientRequestID, selection.ProviderRequestID, true)
	if err != nil || winner.Disposition != AttemptDispositionActive || winner.State == AttemptStateTerminal {
		if err != nil {
			return nil, false, err
		}
		return nil, false, ErrInvalidTransition
	}
	if _, err := tx.Exec(ctx, `UPDATE request_settlements SET winner_attempt_id = $2,
		winner_ingress_sequence = $3, last_ingress_sequence = $3, updated_at = NOW() WHERE client_request_id = $1`,
		selection.ClientRequestID, selection.ProviderRequestID, ingress); err != nil {
		return nil, false, err
	}
	if _, err := tx.Exec(ctx, `UPDATE request_attempts SET disposition = $3, winner_epoch = $4, updated_at = NOW()
		WHERE client_request_id = $1 AND provider_request_id = $2`, selection.ClientRequestID,
		selection.ProviderRequestID, string(AttemptDispositionWinner), selection.ExpectedEpoch); err != nil {
		return nil, false, err
	}
	if _, err := tx.Exec(ctx, `UPDATE request_attempts SET disposition = $3, cancel_state = $6,
		cancel_reason = 'speculative_loser', fence_version = 0, fence_sequence = $7, updated_at = NOW()
		WHERE client_request_id = $1 AND provider_request_id <> $2 AND disposition = $4 AND winner_epoch = $5`,
		selection.ClientRequestID, selection.ProviderRequestID, string(AttemptDispositionSpeculativeLoser),
		string(AttemptDispositionActive), selection.ExpectedEpoch, string(AttemptCancelPending), ingress); err != nil {
		return nil, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, false, err
	}
	result, err := s.GetRequestSettlement(parent, selection.ClientRequestID)
	return result, true, err
}

func (s *PostgresStore) ReleaseRequestWinnerForRetry(parent context.Context, clientID, providerID string, epoch int64) (*RequestSettlement, bool, error) {
	ctx, cancel := settlementContext(parent)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, false, err
	}
	defer tx.Rollback(ctx)
	request, err := getRequestSettlementTx(ctx, tx, clientID, true)
	if err != nil {
		return nil, false, err
	}
	if request.WinnerAttemptID == "" && request.WinnerEpoch == epoch+1 {
		return request, false, tx.Commit(ctx)
	}
	if request.WinnerAttemptID != providerID || request.WinnerEpoch != epoch || request.ProtocolState != "V0" ||
		request.SemanticState != "C0" || request.FenceCause != "" || request.DeliveryState != DeliveryStateNone {
		return nil, false, ErrInvalidTransition
	}
	attempt, err := getRequestAttemptTx(ctx, tx, clientID, providerID, true)
	if err != nil {
		return nil, false, err
	}
	if attempt.Disposition != AttemptDispositionWinner || attempt.State != AttemptStateTerminal {
		return nil, false, ErrInvalidTransition
	}
	var activePeers int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM request_attempts
		WHERE client_request_id = $1 AND provider_request_id <> $2 AND state <> $3`,
		clientID, providerID, string(AttemptStateTerminal)).Scan(&activePeers); err != nil {
		return nil, false, err
	}
	if activePeers != 0 {
		return nil, false, ErrInvalidTransition
	}
	if _, err := tx.Exec(ctx, `UPDATE request_attempts SET disposition = $3, updated_at = NOW()
		WHERE client_request_id = $1 AND provider_request_id = $2`, clientID, providerID, string(AttemptDispositionFailedRetry)); err != nil {
		return nil, false, err
	}
	if _, err := tx.Exec(ctx, `UPDATE request_settlements SET winner_attempt_id = '', winner_ingress_sequence = 0,
		winner_epoch = winner_epoch + 1, state = $2, updated_at = NOW()
		WHERE client_request_id = $1`, clientID, string(RequestStateActive)); err != nil {
		return nil, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, false, err
	}
	result, err := s.GetRequestSettlement(parent, clientID)
	return result, true, err
}

func (s *PostgresStore) FenceRequest(parent context.Context, fence RequestFence) (*RequestSettlement, bool, error) {
	sequence, err := settlementUint64(fence.Sequence)
	if err != nil || fence.ClientRequestID == "" || fence.Cause == "" || sequence == 0 || fence.FenceVersion <= 0 {
		return nil, false, ErrInvalidTransition
	}
	ctx, cancel := settlementContext(parent)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, false, err
	}
	defer tx.Rollback(ctx)
	request, err := getRequestSettlementTx(ctx, tx, fence.ClientRequestID, true)
	if err != nil {
		return nil, false, err
	}
	if request.FenceCause != "" {
		if request.FenceCause == fence.Cause && request.FenceVersion == fence.FenceVersion && request.FenceSequence == fence.Sequence {
			return request, false, tx.Commit(ctx)
		}
		return nil, false, ErrConflict
	}
	if request.EffectsSealed || fence.Sequence <= request.LastIngressSequence {
		return nil, false, ErrInvalidTransition
	}
	rows, err := tx.Query(ctx, `SELECT provider_request_id FROM request_attempts
		WHERE client_request_id = $1 AND state <> $2 FOR UPDATE`, fence.ClientRequestID, string(AttemptStateTerminal))
	if err != nil {
		return nil, false, err
	}
	live := make(map[string]struct{})
	for rows.Next() {
		var attemptID string
		if err := rows.Scan(&attemptID); err != nil {
			rows.Close()
			return nil, false, err
		}
		live[attemptID] = struct{}{}
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, false, err
	}
	rows.Close()
	if len(fence.AttemptIDs) > 0 {
		if len(fence.AttemptIDs) != len(live) {
			return nil, false, ErrInvalidTransition
		}
		seen := make(map[string]struct{}, len(fence.AttemptIDs))
		for _, attemptID := range fence.AttemptIDs {
			if _, duplicate := seen[attemptID]; duplicate {
				return nil, false, ErrInvalidTransition
			}
			if _, ok := live[attemptID]; !ok {
				return nil, false, ErrInvalidTransition
			}
			seen[attemptID] = struct{}{}
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE request_attempts SET
		cancel_state = CASE WHEN cancel_state = $9 THEN $2 ELSE cancel_state END,
		cancel_reason = CASE WHEN cancel_state = $9 THEN $3 ELSE cancel_reason END,
		fence_version = CASE WHEN cancel_state = $9 THEN $4 ELSE fence_version END,
		fence_sequence = CASE WHEN cancel_state = $9 THEN $5 ELSE fence_sequence END,
		disposition = CASE WHEN disposition = $6 THEN $7 ELSE disposition END, updated_at = NOW()
		WHERE client_request_id = $1 AND state <> $8`, fence.ClientRequestID,
		string(AttemptCancelPending), fence.Cause, fence.FenceVersion, sequence,
		string(AttemptDispositionActive), string(AttemptDispositionCancelledByFence), string(AttemptStateTerminal), string(AttemptCancelNone)); err != nil {
		return nil, false, err
	}
	if _, err := tx.Exec(ctx, `UPDATE request_settlements SET fence_cause = $2, fence_version = $3,
		fence_sequence = $4, last_ingress_sequence = $4,
		state = CASE WHEN state IN ($5,$6,$7) THEN $8 ELSE state END, updated_at = NOW()
		WHERE client_request_id = $1`, fence.ClientRequestID, fence.Cause, fence.FenceVersion, sequence,
		string(RequestStateReserved), string(RequestStateActive), string(RequestStateTerminalRecorded), string(RequestStateFenced)); err != nil {
		return nil, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, false, err
	}
	result, err := s.GetRequestSettlement(parent, fence.ClientRequestID)
	return result, true, err
}

func (s *PostgresStore) TransitionAttemptCancel(parent context.Context, transition AttemptCancelTransition) (bool, error) {
	sequence, err := settlementUint64(transition.FenceSequence)
	if err != nil || transition.ClientRequestID == "" || transition.ProviderRequestID == "" ||
		transition.FenceVersion < 0 || sequence == 0 || !validCancelTransition(transition.From, transition.To) {
		return false, ErrInvalidTransition
	}
	ctx, cancel := settlementContext(parent)
	defer cancel()
	command, err := s.pool.Exec(ctx, `UPDATE request_attempts SET cancel_state = $6, updated_at = NOW()
		WHERE client_request_id = $1 AND provider_request_id = $2 AND fence_version = $3
		  AND fence_sequence = $4 AND cancel_state = $5`,
		transition.ClientRequestID, transition.ProviderRequestID, transition.FenceVersion, sequence,
		string(transition.From), string(transition.To))
	if err != nil {
		return false, err
	}
	if command.RowsAffected() == 1 {
		return true, nil
	}
	attempt, err := s.GetRequestAttempt(parent, transition.ClientRequestID, transition.ProviderRequestID)
	if err != nil {
		return false, err
	}
	if attempt.FenceVersion != transition.FenceVersion || attempt.FenceSequence != transition.FenceSequence {
		return false, ErrInvalidTransition
	}
	if attempt.CancelState == transition.To {
		return false, nil
	}
	return false, ErrInvalidTransition
}

func (s *PostgresStore) ClaimAttemptTerminal(parent context.Context, claim AttemptTerminalClaim) (*AttemptTerminal, bool, error) {
	terminal := claim.Terminal
	if terminal.ClientRequestID == "" || terminal.ProviderRequestID == "" || terminal.IngressSequence == 0 ||
		terminal.PromptTokens < 0 || terminal.CompletionTokens < 0 || terminal.ReasoningTokens < 0 ||
		terminal.LastCompletionTokens < 0 || terminal.LastCompletionTokens > terminal.CompletionTokens ||
		!validSettlementSnapshot(terminal.Snapshot, terminal.SnapshotHash) {
		return nil, false, ErrInvalidTransition
	}
	ingress, err := settlementUint64(terminal.IngressSequence)
	if err != nil {
		return nil, false, err
	}
	lastChunk, err := settlementUint64(terminal.LastChunkSequence)
	if err != nil {
		return nil, false, err
	}
	fenceSequence, err := settlementUint64(terminal.RequestFenceSequence)
	if err != nil {
		return nil, false, err
	}
	ctx, cancel := settlementContext(parent)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, false, err
	}
	defer tx.Rollback(ctx)
	if err := lockSettlementKey(ctx, tx, "terminal:"+terminal.ProviderRequestID); err != nil {
		return nil, false, err
	}
	if existing, err := getAttemptTerminalTx(ctx, tx, terminal.ClientRequestID, terminal.ProviderRequestID); err == nil {
		if existing.SnapshotHash != terminal.SnapshotHash || !bytes.Equal(existing.Snapshot, terminal.Snapshot) {
			return existing, false, ErrConflict
		}
		return existing, false, tx.Commit(ctx)
	} else if !errors.Is(err, ErrNotFound) {
		return nil, false, err
	}
	request, err := getRequestSettlementTx(ctx, tx, terminal.ClientRequestID, true)
	if err != nil {
		return nil, false, err
	}
	if request.EffectsSealed || terminal.IngressSequence <= request.LastIngressSequence {
		return nil, false, ErrInvalidTransition
	}
	attempt, err := getRequestAttemptTx(ctx, tx, terminal.ClientRequestID, terminal.ProviderRequestID, true)
	if err != nil {
		return nil, false, err
	}
	if terminal.AdmissionState == "" {
		terminal.AdmissionState = attempt.AdmissionState
	}
	if attempt.State == AttemptStateTerminal || admissionRank(terminal.AdmissionState) < admissionRank(attempt.AdmissionState) {
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
	_, err = tx.Exec(ctx, `INSERT INTO attempt_terminals (
		client_request_id, provider_request_id, ingress_sequence, snapshot_hash, snapshot,
		metadata_version, envelope, kind, cause, stage, source, admission_state, prompt_tokens,
		completion_tokens, reasoning_tokens, last_chunk_sequence, last_completion_tokens,
		termination_reason, request_fence_version, request_fence_sequence, cancel_reason,
		response_hash, transcript_hash, terminal_hash, terminal_signature, evidence_valid, health_outcome
	) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25,$26,$27)`,
		terminal.ClientRequestID, terminal.ProviderRequestID, ingress, terminal.SnapshotHash,
		[]byte(terminal.Snapshot), terminal.MetadataVersion, terminal.Envelope, terminal.Kind,
		terminal.Cause, terminal.Stage, terminal.Source, terminal.AdmissionState,
		terminal.PromptTokens, terminal.CompletionTokens, terminal.ReasoningTokens, lastChunk,
		terminal.LastCompletionTokens, terminal.TerminationReason, terminal.RequestFenceVersion,
		fenceSequence, terminal.CancelReason, terminal.ResponseHash, terminal.TranscriptHash,
		terminal.TerminalHash, terminal.TerminalSignature, terminal.EvidenceValid, terminal.HealthOutcome)
	if err != nil {
		return nil, false, fmt.Errorf("insert attempt terminal: %w", err)
	}
	cancelState := string(attempt.CancelState)
	if terminal.Kind == "cancelled" {
		cancelState = string(AttemptCancelAcknowledged)
	}
	if _, err := tx.Exec(ctx, `UPDATE request_attempts SET state = $3, admission_state = $4,
		cancel_state = $5, updated_at = NOW() WHERE client_request_id = $1 AND provider_request_id = $2`,
		terminal.ClientRequestID, terminal.ProviderRequestID, string(AttemptStateTerminal),
		terminal.AdmissionState, cancelState); err != nil {
		return nil, false, err
	}
	if claim.EmptyWinner != nil {
		if _, err := tx.Exec(ctx, `UPDATE request_attempts SET disposition = $3, winner_epoch = $4, updated_at = NOW()
			WHERE client_request_id = $1 AND provider_request_id = $2`, terminal.ClientRequestID,
			terminal.ProviderRequestID, string(AttemptDispositionWinner), request.WinnerEpoch); err != nil {
			return nil, false, err
		}
		if _, err := tx.Exec(ctx, `UPDATE request_attempts SET disposition = $3, cancel_state = $6,
			cancel_reason = 'speculative_loser', fence_version = 0, fence_sequence = $7, updated_at = NOW()
			WHERE client_request_id = $1 AND provider_request_id <> $2 AND disposition = $4 AND winner_epoch = $5`,
			terminal.ClientRequestID, terminal.ProviderRequestID, string(AttemptDispositionSpeculativeLoser),
			string(AttemptDispositionActive), request.WinnerEpoch, string(AttemptCancelPending), ingress); err != nil {
			return nil, false, err
		}
	}
	var nonterminal int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM request_attempts WHERE client_request_id = $1 AND state <> $2`,
		terminal.ClientRequestID, string(AttemptStateTerminal)).Scan(&nonterminal); err != nil {
		return nil, false, err
	}
	requestState := request.State
	if nonterminal == 0 && (requestState == RequestStateReserved || requestState == RequestStateActive) {
		requestState = RequestStateTerminalRecorded
	}
	winnerID := request.WinnerAttemptID
	winnerIngress := request.WinnerIngressSequence
	if claim.EmptyWinner != nil {
		winnerID = terminal.ProviderRequestID
		winnerIngress = terminal.IngressSequence
	}
	if _, err := tx.Exec(ctx, `UPDATE request_settlements SET last_ingress_sequence = $2,
		winner_attempt_id = $3, winner_ingress_sequence = $4, state = $5, updated_at = NOW()
		WHERE client_request_id = $1`, terminal.ClientRequestID, ingress, winnerID, winnerIngress, string(requestState)); err != nil {
		return nil, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, false, err
	}
	created, err := s.GetAttemptTerminal(parent, terminal.ClientRequestID, terminal.ProviderRequestID)
	return created, true, err
}

func (s *PostgresStore) AdvanceDeliveryCheckpoint(parent context.Context, checkpoint DeliveryCheckpoint) (*RequestSettlement, bool, error) {
	ingress, err := settlementUint64(checkpoint.IngressSequence)
	if err != nil || checkpoint.ClientRequestID == "" || ingress == 0 || checkpoint.WrittenCompletionTokens < 0 ||
		deliveryStateRank(checkpoint.TransportState, "T0", "T1", "") < 0 ||
		deliveryStateRank(checkpoint.ProtocolState, "V0", "V1", "V2") < 0 ||
		deliveryStateRank(checkpoint.SemanticState, "C0", "C1", "") < 0 {
		return nil, false, ErrInvalidTransition
	}
	writtenChunk, err := settlementUint64(checkpoint.WrittenChunkSequence)
	if err != nil {
		return nil, false, err
	}
	ctx, cancel := settlementContext(parent)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, false, err
	}
	defer tx.Rollback(ctx)
	request, err := getRequestSettlementTx(ctx, tx, checkpoint.ClientRequestID, true)
	if err != nil {
		return nil, false, err
	}
	if request.ClientSnapshotHash != "" || request.EffectsSealed || request.DeliveryState != DeliveryStateNone {
		return nil, false, ErrInvalidTransition
	}
	if checkpoint.IngressSequence == request.WrittenIngressSequence {
		if checkpoint.TransportState == request.TransportState && checkpoint.ProtocolState == request.ProtocolState &&
			checkpoint.SemanticState == request.SemanticState && checkpoint.WrittenChunkSequence == request.WrittenChunkSequence &&
			checkpoint.WrittenCompletionTokens == request.WrittenCompletionTokens && checkpoint.WrittenCommitment == request.WrittenCommitment {
			return request, false, tx.Commit(ctx)
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
	lastIngress := request.LastIngressSequence
	if checkpoint.IngressSequence > lastIngress {
		lastIngress = checkpoint.IngressSequence
	}
	if _, err := tx.Exec(ctx, `UPDATE request_settlements SET transport_state = $2,
		protocol_state = $3, semantic_state = $4, written_ingress_sequence = $5,
		written_chunk_sequence = $6, written_completion_tokens = $7, written_commitment = $8,
		last_ingress_sequence = $9, updated_at = NOW() WHERE client_request_id = $1`,
		checkpoint.ClientRequestID, checkpoint.TransportState, checkpoint.ProtocolState,
		checkpoint.SemanticState, ingress, writtenChunk, checkpoint.WrittenCompletionTokens,
		checkpoint.WrittenCommitment, lastIngress); err != nil {
		return nil, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, false, err
	}
	result, err := s.GetRequestSettlement(parent, checkpoint.ClientRequestID)
	return result, true, err
}

func (s *PostgresStore) RecordDeliveryResult(parent context.Context, clientID, snapshotHash string, state DeliveryState, snapshot json.RawMessage) (*RequestSettlement, bool, error) {
	if clientID == "" || (state != DeliveryStatePending && state != DeliveryStateConfirmed &&
		state != DeliveryStateFailed && state != DeliveryStateIndeterminate) ||
		(state != DeliveryStatePending && !validSettlementSnapshot(snapshot, snapshotHash)) {
		return nil, false, ErrInvalidTransition
	}
	ctx, cancel := settlementContext(parent)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, false, err
	}
	defer tx.Rollback(ctx)
	request, err := getRequestSettlementTx(ctx, tx, clientID, true)
	if err != nil {
		return nil, false, err
	}
	if state == DeliveryStatePending {
		if request.DeliveryState == DeliveryStatePending {
			return request, false, tx.Commit(ctx)
		}
		if request.DeliveryState != DeliveryStateNone {
			return nil, false, ErrInvalidTransition
		}
		if _, err := tx.Exec(ctx, `UPDATE request_settlements SET delivery_state = $2, state = $3, updated_at = NOW()
			WHERE client_request_id = $1`, clientID, string(state), string(RequestStateDeliveryPending)); err != nil {
			return nil, false, err
		}
	} else {
		if request.ClientSnapshotHash != "" {
			if request.ClientSnapshotHash == snapshotHash && request.DeliveryState == state {
				return request, false, tx.Commit(ctx)
			}
			return nil, false, ErrConflict
		}
		if request.DeliveryState != DeliveryStateNone && request.DeliveryState != DeliveryStatePending {
			return nil, false, ErrInvalidTransition
		}
		if _, err := tx.Exec(ctx, `UPDATE request_settlements SET delivery_state = $2,
			client_snapshot_hash = $3, client_snapshot = $4, state = $5, updated_at = NOW()
			WHERE client_request_id = $1`, clientID, string(state), snapshotHash, []byte(snapshot),
			string(RequestStateDeliveryRecorded)); err != nil {
			return nil, false, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, false, err
	}
	result, err := s.GetRequestSettlement(parent, clientID)
	return result, true, err
}

func (s *PostgresStore) SealSettlementEffects(parent context.Context, clientID, clientHash, settlementHash string, snapshot json.RawMessage, effects []SettlementEffect) (*RequestSettlement, bool, error) {
	if clientID == "" || clientHash == "" || !validSettlementSnapshot(snapshot, settlementHash) {
		return nil, false, ErrInvalidTransition
	}
	ctx, cancel := settlementContext(parent)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, false, err
	}
	defer tx.Rollback(ctx)
	request, err := getRequestSettlementTx(ctx, tx, clientID, true)
	if err != nil {
		return nil, false, err
	}
	if request.EffectsSealed {
		existingEffects, listErr := listSettlementEffectsTx(ctx, tx, clientID)
		if listErr != nil {
			return nil, false, listErr
		}
		if request.ClientSnapshotHash == clientHash && request.SettlementSnapshotHash == settlementHash &&
			sameSealedEffectPlan(existingEffects, effects) {
			return request, false, tx.Commit(ctx)
		}
		return nil, false, ErrConflict
	}
	if request.ClientSnapshotHash != clientHash || request.State != RequestStateDeliveryRecorded {
		return nil, false, ErrInvalidTransition
	}
	attempts, err := listRequestAttemptsTx(ctx, tx, clientID)
	if err != nil {
		return nil, false, err
	}
	for i := range attempts {
		if attempts[i].State != AttemptStateTerminal {
			return nil, false, ErrInvalidTransition
		}
	}
	seenIDs := make(map[string]struct{}, len(effects))
	seenKeys := make(map[string]struct{}, len(effects))
	for i := range effects {
		effect := effects[i]
		effect.SealedPlan = true
		if effect.ClientRequestID != clientID || effect.EffectID == "" || effect.IdempotencyKey == "" || effect.AmountMicroUSD < 0 {
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
	existingEffects, err := listSettlementEffectsTx(ctx, tx, clientID)
	if err != nil {
		return nil, false, err
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
		dependsOn := effect.DependsOn
		if dependsOn == nil {
			dependsOn = []string{}
		}
		depends, err := json.Marshal(dependsOn)
		if err != nil {
			return nil, false, err
		}
		_, err = tx.Exec(ctx, `INSERT INTO settlement_effects (
			effect_id, client_request_id, provider_request_id, effect_type, target_kind,
			beneficiary, idempotency_key, amount_micro_usd, depends_on, payload, sealed_plan, state, last_error
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb,$10::jsonb,$11,$12,$13)`,
			effect.EffectID, effect.ClientRequestID, effect.ProviderRequestID, string(effect.Type),
			effect.TargetKind, effect.Beneficiary, effect.IdempotencyKey, effect.AmountMicroUSD,
			string(depends), nullableJSONRaw(effect.Payload), effect.SealedPlan, string(effect.State), effect.LastError)
		if err != nil {
			return nil, false, fmt.Errorf("insert settlement effect: %w", err)
		}
	}
	settlementState := RequestStateSettled
	for _, effect := range append(existingEffects, effects...) {
		state := effect.State
		if state == "" {
			state = EffectStatePending
		}
		if state != EffectStateApplied && state != EffectStateNotApplicable {
			settlementState = RequestStateSettling
			break
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE request_settlements SET settlement_snapshot_hash = $2,
		settlement_snapshot = $3, effects_sealed = TRUE, state = $4, updated_at = NOW()
		WHERE client_request_id = $1`, clientID, settlementHash, []byte(snapshot), string(settlementState)); err != nil {
		return nil, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, false, err
	}
	result, err := s.GetRequestSettlement(parent, clientID)
	return result, true, err
}

func (s *PostgresStore) ClaimReadySettlementEffect(parent context.Context, params ClaimSettlementEffectParams) (*SettlementEffect, error) {
	if params.WorkerID == "" || params.Lease <= 0 {
		return nil, ErrInvalidTransition
	}
	if params.Now.IsZero() {
		params.Now = time.Now().UTC()
	}
	expires := params.Now.Add(params.Lease)
	ctx, cancel := settlementContext(parent)
	defer cancel()
	return scanSettlementJSON[SettlementEffect](s.pool.QueryRow(ctx, `
		WITH candidate AS (
			SELECT e.effect_id
			FROM settlement_effects e
			JOIN request_settlements r ON r.client_request_id = e.client_request_id
			WHERE r.effects_sealed = TRUE AND r.state = $1
			  AND (e.state IN ($2,$3) OR (e.state = $4 AND e.claim_expires_at <= $5))
			  AND NOT EXISTS (
				SELECT 1
				FROM jsonb_array_elements_text(e.depends_on) dependency(effect_id)
				LEFT JOIN settlement_effects required ON required.effect_id = dependency.effect_id
				WHERE required.effect_id IS NULL OR required.state <> $6
			  )
			ORDER BY e.created_at, e.effect_id
			FOR UPDATE OF e SKIP LOCKED
			LIMIT 1
		)
		UPDATE settlement_effects e
		SET state = $4, claim_owner = $7, claim_expires_at = $8,
		    apply_attempts = apply_attempts + 1, updated_at = $5
		FROM candidate
		WHERE e.effect_id = candidate.effect_id
		RETURNING to_jsonb(e)`,
		string(RequestStateSettling), string(EffectStatePending), string(EffectStateIndeterminate),
		string(EffectStateApplying), params.Now, string(EffectStateApplied), params.WorkerID, expires))
}

func (s *PostgresStore) CompleteSettlementEffect(parent context.Context, params CompleteSettlementEffectParams) (*SettlementEffect, bool, error) {
	if params.EffectID == "" || params.IdempotencyKey == "" || params.WorkerID == "" ||
		(params.State != EffectStateApplied && params.State != EffectStateNotApplicable &&
			params.State != EffectStateIndeterminate && params.State != EffectStateManualReview) {
		return nil, false, ErrInvalidTransition
	}
	ctx, cancel := settlementContext(parent)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, false, err
	}
	defer tx.Rollback(ctx)
	var keyedID string
	if err := tx.QueryRow(ctx, `SELECT effect_id FROM settlement_effects WHERE idempotency_key = $1`, params.IdempotencyKey).Scan(&keyedID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, false, ErrNotFound
		}
		return nil, false, err
	}
	if keyedID != params.EffectID {
		return nil, false, ErrConflict
	}
	effect, err := getSettlementEffectTx(ctx, tx, params.EffectID, true)
	if err != nil {
		return nil, false, err
	}
	if effect.State == params.State && effect.ClaimOwner == "" {
		return effect, false, tx.Commit(ctx)
	}
	if effect.State != EffectStateApplying || effect.ClaimOwner != params.WorkerID {
		return nil, false, ErrInvalidTransition
	}
	updated, err := scanSettlementJSON[SettlementEffect](tx.QueryRow(ctx, `UPDATE settlement_effects
		SET state = $2, last_error = $3, claim_owner = '', claim_expires_at = NULL, updated_at = NOW()
		WHERE effect_id = $1 RETURNING to_jsonb(settlement_effects)`,
		params.EffectID, string(params.State), params.LastError))
	if err != nil {
		return nil, false, err
	}
	if params.State == EffectStateManualReview {
		if _, err := tx.Exec(ctx, `UPDATE request_settlements SET state = $2, updated_at = NOW() WHERE client_request_id = $1`,
			effect.ClientRequestID, string(RequestStateManualReview)); err != nil {
			return nil, false, err
		}
	} else if params.State == EffectStateApplied || params.State == EffectStateNotApplicable {
		var remaining bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM settlement_effects
			WHERE client_request_id = $1 AND state NOT IN ($2,$3))`, effect.ClientRequestID,
			string(EffectStateApplied), string(EffectStateNotApplicable)).Scan(&remaining); err != nil {
			return nil, false, err
		}
		if !remaining {
			if _, err := tx.Exec(ctx, `UPDATE request_settlements SET state = $2, updated_at = NOW()
				WHERE client_request_id = $1 AND effects_sealed = TRUE`, effect.ClientRequestID, string(RequestStateSettled)); err != nil {
				return nil, false, err
			}
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, false, err
	}
	return updated, true, nil
}

func (s *PostgresStore) GetRequestSettlement(parent context.Context, clientID string) (*RequestSettlement, error) {
	ctx, cancel := settlementContext(parent)
	defer cancel()
	return scanSettlementJSON[RequestSettlement](s.pool.QueryRow(ctx,
		`SELECT to_jsonb(r) FROM request_settlements r WHERE client_request_id = $1`, clientID))
}

func (s *PostgresStore) GetRequestAttempt(parent context.Context, clientID, providerID string) (*RequestAttempt, error) {
	ctx, cancel := settlementContext(parent)
	defer cancel()
	return scanSettlementJSON[RequestAttempt](s.pool.QueryRow(ctx,
		`SELECT to_jsonb(a) FROM request_attempts a WHERE client_request_id = $1 AND provider_request_id = $2`,
		clientID, providerID))
}

func (s *PostgresStore) GetAttemptTerminal(parent context.Context, clientID, providerID string) (*AttemptTerminal, error) {
	ctx, cancel := settlementContext(parent)
	defer cancel()
	return scanSettlementJSON[AttemptTerminal](s.pool.QueryRow(ctx,
		`SELECT to_jsonb(t) FROM attempt_terminals t WHERE client_request_id = $1 AND provider_request_id = $2`,
		clientID, providerID))
}

func (s *PostgresStore) ListSettlementEffects(parent context.Context, clientID string) ([]SettlementEffect, error) {
	ctx, cancel := settlementContext(parent)
	defer cancel()
	rows, err := s.pool.Query(ctx, `SELECT to_jsonb(e) FROM settlement_effects e WHERE client_request_id = $1 ORDER BY effect_id`, clientID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]SettlementEffect, 0)
	for rows.Next() {
		effect, err := scanSettlementJSON[SettlementEffect](rows)
		if err != nil {
			return nil, err
		}
		result = append(result, *effect)
	}
	return result, rows.Err()
}

func (s *PostgresStore) ListRecoverableRequestSettlements(parent context.Context, limit int) ([]RequestSettlement, error) {
	if limit <= 0 || limit > 10000 {
		limit = 1000
	}
	ctx, cancel := settlementContext(parent)
	defer cancel()
	rows, err := s.pool.Query(ctx, `SELECT to_jsonb(r) FROM request_settlements r
		WHERE state NOT IN ('settled', 'manual_review') ORDER BY created_at LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]RequestSettlement, 0)
	for rows.Next() {
		request, err := scanSettlementJSON[RequestSettlement](rows)
		if err != nil {
			return nil, err
		}
		result = append(result, *request)
	}
	return result, rows.Err()
}

var _ SettlementStore = (*PostgresStore)(nil)
