package api

// Best-effort, money-neutral mirroring of the request actor's authoritative
// control-flow decisions into the durable settlement journal (coordinator/store).
//
// Nothing here can change the client-visible or financial outcome: journaling is
// gated by a kill switch, runs off the request's critical path through the
// injected journal runner, swallows every error into a metric, and never moves
// money (the request row is created with ServiceHold=true and a zero reserved
// amount, and attempts carry a zero top-up). Its purpose is to give the durable
// journal real production shape and exercise the store's invariants for real, so
// the later step that flips finance onto the journal has less to change. The
// process-local reservation/billing code remains the money authority in this
// step.

import (
	"context"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// envSettlementJournal is the kill switch for settlement-journal mirroring.
// Default true: the actor journals its terminal/winner/retry/fence decisions.
// Because journaling is money-neutral and off the request's critical path,
// disabling it changes nothing the client or ledger observes; the switch exists
// purely as an operational safety valve.
const envSettlementJournal = "EIGENINFERENCE_SETTLEMENT_JOURNAL"

func settlementJournalEnabled() bool { return envEnabledDefaultTrue(envSettlementJournal) }

// journalTerminal maps a terminalKind to the (kind, cause, envelope) strings the
// settlement journal records. It is shadow metadata only; the wire-accurate v1
// terminal vocabulary is a later step. Only a clean completion journals as
// kind="complete"; every non-success terminal journals as kind="error" so the
// journal never has to satisfy the store's cancelled-terminal fence checks with
// synthetic data.
func (k terminalKind) journalTerminal() (kind, cause, envelope string) {
	switch k {
	case terminalComplete:
		return "complete", "stop", "inference_complete"
	case terminalError:
		return "error", "provider_error", "inference_error"
	case terminalTimeout:
		return "error", "attempt_budget_exhausted", "inference_error"
	case terminalDisconnect:
		return "error", "provider_disconnect", "inference_error"
	case terminalCancel:
		return "error", "request_error", "inference_error"
	default:
		return "error", "no_terminal", "inference_error"
	}
}

// runJournal executes a store op through the injected runner and records any
// error as a metric. It never returns anything the caller acts on.
func (a *requestActor) runJournal(name string, op func(context.Context) error) {
	if a == nil || a.store == nil || a.journal == nil {
		return
	}
	a.journal(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := op(ctx); err != nil && a.onJournalErr != nil {
			a.onJournalErr(name, err)
		}
	})
}

// journalReservation inserts the logical request row exactly once. It is
// deliberately money-neutral: ServiceHold=true skips any ledger debit in both
// store backends, and a zero ReservedMicroUSD means no balance is moved even in
// the hold-accounting path. Real reserved/charged amounts are a step-7 concern.
func (a *requestActor) journalReservation() {
	if a == nil || a.consumerAccount == "" {
		return
	}
	a.reservedOnce.Do(func() {
		req := store.RequestSettlement{
			ClientRequestID:   a.logicalID,
			ConsumerAccountID: a.consumerAccount,
			Model:             a.model,
			PublicModel:       a.publicModel,
			Endpoint:          a.endpoint,
			Stream:            a.stream,
			ReservedMicroUSD:  0,
			RequestBudgetMS:   a.budgetMS,
			StartedAt:         time.Now(),
		}
		a.runJournal("begin_reservation", func(ctx context.Context) error {
			_, _, err := a.store.BeginRequestReservation(ctx, store.BeginRequestReservationParams{
				Request:     req,
				ServiceHold: true,
			})
			return err
		})
	})
}

func (a *requestActor) journalAttempt(attemptID, providerID, role string, ordinal int) {
	attempt := store.RequestAttempt{
		ClientRequestID:   a.logicalID,
		ProviderRequestID: attemptID,
		ProviderID:        providerID,
		Attempt:           ordinal,
		Role:              role,
		BudgetMS:          a.budgetMS,
		TopUpMicroUSD:     0,
	}
	a.runJournal("begin_attempt", func(ctx context.Context) error {
		if _, _, err := a.store.BeginAttemptBeforeDispatch(ctx, store.BeginAttemptParams{Attempt: attempt}); err != nil {
			return err
		}
		return a.store.MarkAttemptDispatched(ctx, a.logicalID, attemptID, time.Now())
	})
}

func (a *requestActor) journalWinner(attemptID string, epoch int64, seq uint64) {
	a.runJournal("select_winner", func(ctx context.Context) error {
		_, _, err := a.store.SelectRequestWinner(ctx, store.WinnerSelection{
			ClientRequestID:   a.logicalID,
			ProviderRequestID: attemptID,
			ExpectedEpoch:     epoch,
			IngressSequence:   seq,
		})
		return err
	})
}

func (a *requestActor) journalRelease(attemptID string, epoch int64) {
	a.runJournal("release_winner", func(ctx context.Context) error {
		_, _, err := a.store.ReleaseRequestWinnerForRetry(ctx, a.logicalID, attemptID, epoch)
		return err
	})
}

func (a *requestActor) journalTerminalRow(attemptID string, k terminalKind) {
	kind, cause, envelope := k.journalTerminal()
	seq := a.nextIngress()
	snapshot := []byte(fmt.Sprintf(`{"attempt":%q,"kind":%q,"cause":%q}`, attemptID, kind, cause))
	term := store.AttemptTerminal{
		ClientRequestID:   a.logicalID,
		ProviderRequestID: attemptID,
		IngressSequence:   seq,
		SnapshotHash:      store.HashSettlementSnapshot(snapshot),
		Snapshot:          snapshot,
		Envelope:          envelope,
		Kind:              kind,
		Cause:             cause,
		Stage:             "decode",
		Source:            "provider",
	}
	a.runJournal("claim_terminal", func(ctx context.Context) error {
		_, _, err := a.store.ClaimAttemptTerminal(ctx, store.AttemptTerminalClaim{Terminal: term})
		return err
	})
}

func (a *requestActor) journalFence(cause string, seq uint64) {
	a.runJournal("fence_request", func(ctx context.Context) error {
		_, _, err := a.store.FenceRequest(ctx, store.RequestFence{
			ClientRequestID: a.logicalID,
			Cause:           cause,
			Sequence:        seq,
			FenceVersion:    1,
		})
		return err
	})
}
