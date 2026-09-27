package store

import (
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"time"
)

const (
	InferenceReceiptPending     = "pending"
	InferenceReceiptCompleted   = "completed"
	InferenceReceiptFailed      = "failed"
	InferenceReceiptInterrupted = "interrupted"

	MaxInferenceReceiptPruneLimit = 1000
)

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
