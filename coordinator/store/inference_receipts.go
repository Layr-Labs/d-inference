package store

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Inference receipt lifecycle states. Pending is the only non-terminal state.
const (
	InferenceReceiptPending     = "pending"
	InferenceReceiptCompleted   = "completed"
	InferenceReceiptFailed      = "failed"
	InferenceReceiptInterrupted = "interrupted"

	// MaxInferenceReceiptPruneLimit caps one maintenance batch so a large
	// backlog is drained in short transactions rather than one long lock.
	MaxInferenceReceiptPruneLimit = 1000
)

// InferenceReceiptStore persists the lifecycle and signed evidence envelope
// for each receipt-enabled inference job. It is an optional capability, not an
// embedded member of Store: callers discover it with As[InferenceReceiptStore],
// which unwraps decorators, and treat its absence as "receipts unavailable".
//
// The lifecycle is pending -> completed | failed | interrupted, and terminal
// rows never change again. Speculative backups and retries can race to finish
// the same job, so completion is a single-winner compare-and-set: exactly one
// attempt's output can become the receipt, and a late attempt can neither
// overwrite it nor downgrade it to failed.
type InferenceReceiptStore interface {
	// CreateInferenceReceipt stores a new pending row. Job IDs, nonces and
	// receipt hashes are each unique across all rows; a collision returns
	// ErrInferenceReceiptConflict. Nonces are unique across every caller, not
	// per key: a verifier that issued a nonce can then trust that exactly one
	// receipt ever carries it.
	CreateInferenceReceipt(context.Context, InferenceReceiptRecord) error
	// CompleteInferenceReceipt atomically completes a pending job and returns
	// true only when this call made the transition. Repeated or conflicting
	// completions never overwrite an existing terminal record.
	CompleteInferenceReceipt(ctx context.Context, jobID, receiptHash string, envelope []byte, completedAt, expiresAt time.Time) (bool, error)
	// SetInferenceReceiptState moves a pending receipt to failed or interrupted;
	// terminal records are never downgraded, so calling it after completion is
	// a no-op.
	SetInferenceReceiptState(ctx context.Context, jobID, state string, updatedAt time.Time) error
	// GetInferenceReceiptByJobID returns the row for its job ID, or ErrNotFound.
	GetInferenceReceiptByJobID(ctx context.Context, jobID string) (InferenceReceiptRecord, error)
	// GetInferenceReceiptByHash returns only completed, unexpired receipts, or
	// ErrNotFound.
	GetInferenceReceiptByHash(ctx context.Context, receiptHash string) (InferenceReceiptRecord, error)
	// InterruptStaleInferenceReceipts changes up to limit pending receipts created
	// at or before staleBefore to interrupted, oldest first. The transition time
	// must not precede any receipt's creation time. It recovers rows orphaned by
	// a coordinator restart mid-request.
	InterruptStaleInferenceReceipts(ctx context.Context, staleBefore, interruptedAt time.Time, limit int) (int, error)
	// PruneInferenceReceipts removes up to limit rows whose expiry is at or
	// before before, including expired pending rows.
	PruneInferenceReceipts(ctx context.Context, before time.Time, limit int) (int, error)
}

// ErrInferenceReceiptConflict reports a duplicate job ID, nonce or receipt hash.
var ErrInferenceReceiptConflict = errors.New("inference receipt conflicts with existing data")

// InferenceReceiptRecord is the durable receipt envelope and lifecycle state
// for one inference job. Envelope is opaque serialized receipt data and is
// present only for completed receipts.
type InferenceReceiptRecord struct {
	JobID       string    `json:"job_id"`
	Nonce       string    `json:"nonce"`
	ReceiptHash string    `json:"receipt_hash,omitempty"`
	State       string    `json:"state"`
	Envelope    []byte    `json:"envelope,omitempty"`
	CreatedAt   time.Time `json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
	ExpiresAt   time.Time `json:"expires_at"`
}

func normalizeInferenceReceipt(rec InferenceReceiptRecord) (InferenceReceiptRecord, error) {
	if rec.CreatedAt.IsZero() {
		rec.CreatedAt = time.Now().UTC()
	}
	if rec.UpdatedAt.IsZero() {
		rec.UpdatedAt = rec.CreatedAt
	}
	rec.Envelope = cloneReceiptEnvelope(rec.Envelope)
	if err := validateInferenceReceipt(rec); err != nil {
		return InferenceReceiptRecord{}, err
	}
	return rec, nil
}

func validateInferenceReceipt(rec InferenceReceiptRecord) error {
	if strings.TrimSpace(rec.JobID) == "" {
		return errors.New("store: inference receipt job ID is required")
	}
	if !validInferenceReceiptNonce(rec.Nonce) {
		return errors.New("store: inference receipt nonce must be canonical base64url for 32 bytes")
	}
	if rec.ExpiresAt.IsZero() || !rec.ExpiresAt.After(rec.CreatedAt) {
		return errors.New("store: inference receipt expiry must be after creation")
	}
	if rec.UpdatedAt.IsZero() || rec.UpdatedAt.Before(rec.CreatedAt) {
		return errors.New("store: invalid inference receipt timestamps")
	}
	switch rec.State {
	case InferenceReceiptPending, InferenceReceiptFailed, InferenceReceiptInterrupted:
		if rec.ReceiptHash != "" || len(rec.Envelope) != 0 {
			return errors.New("store: non-completed inference receipt cannot contain receipt data")
		}
	case InferenceReceiptCompleted:
		if strings.TrimSpace(rec.ReceiptHash) == "" || len(rec.Envelope) == 0 {
			return errors.New("store: completed inference receipt requires a hash and envelope")
		}
	default:
		return fmt.Errorf("store: invalid inference receipt state %q", rec.State)
	}
	return nil
}

func validInferenceReceiptNonce(nonce string) bool {
	if len(nonce) != 43 {
		return false
	}
	decoded, err := base64.RawURLEncoding.Strict().DecodeString(nonce)
	return err == nil && len(decoded) == 32 && base64.RawURLEncoding.EncodeToString(decoded) == nonce
}

func validateInferenceReceiptCompletion(jobID, receiptHash string, envelope []byte, completedAt, expiresAt time.Time) error {
	if strings.TrimSpace(jobID) == "" || strings.TrimSpace(receiptHash) == "" {
		return errors.New("store: inference receipt job ID and hash are required")
	}
	if len(envelope) == 0 {
		return errors.New("store: completed inference receipt envelope is required")
	}
	if completedAt.IsZero() || expiresAt.IsZero() || !expiresAt.After(completedAt) {
		return errors.New("store: inference receipt expiry must be after completion")
	}
	return nil
}

func validateInferenceReceiptLifecycleTime(createdAt, transitionAt time.Time) error {
	if transitionAt.IsZero() {
		return errors.New("store: inference receipt lifecycle timestamp is required")
	}
	if transitionAt.Before(createdAt) {
		return errors.New("store: inference receipt lifecycle timestamp precedes creation")
	}
	return nil
}

func cloneReceiptEnvelope(envelope []byte) []byte {
	if envelope == nil {
		return nil
	}
	return append([]byte(nil), envelope...)
}

func cloneInferenceReceipt(rec InferenceReceiptRecord) InferenceReceiptRecord {
	rec.Envelope = cloneReceiptEnvelope(rec.Envelope)
	return rec
}

func inferenceReceiptLimit(limit int) int {
	if limit < 1 {
		return 0
	}
	if limit > MaxInferenceReceiptPruneLimit {
		return MaxInferenceReceiptPruneLimit
	}
	return limit
}

func inferenceReceiptTerminal(state string) bool {
	return state == InferenceReceiptCompleted || state == InferenceReceiptFailed || state == InferenceReceiptInterrupted
}
