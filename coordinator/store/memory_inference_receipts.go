package store

import (
	"context"
	"errors"
	"sort"
	"strings"
	"time"
)

var _ InferenceReceiptStore = (*MemoryStore)(nil)

func (s *MemoryStore) CreateInferenceReceipt(ctx context.Context, rec InferenceReceiptRecord) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	rec, err := normalizeInferenceReceipt(rec)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.inferenceReceipts == nil {
		s.inferenceReceipts = make(map[string]InferenceReceiptRecord)
	}
	if _, exists := s.inferenceReceipts[rec.JobID]; exists {
		return ErrInferenceReceiptConflict
	}
	if rec.ReceiptHash != "" && s.inferenceReceiptHashExistsLocked(rec.ReceiptHash, "") {
		return ErrInferenceReceiptConflict
	}
	if s.inferenceReceiptNonceExistsLocked(rec.Nonce, "") {
		return ErrInferenceReceiptConflict
	}
	s.inferenceReceipts[rec.JobID] = cloneInferenceReceipt(rec)
	return nil
}

func (s *MemoryStore) CompleteInferenceReceipt(ctx context.Context, jobID, receiptHash string, envelope []byte, completedAt, expiresAt time.Time) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if err := validateInferenceReceiptCompletion(jobID, receiptHash, envelope, completedAt, expiresAt); err != nil {
		return false, err
	}
	envelope = cloneReceiptEnvelope(envelope)
	s.mu.Lock()
	defer s.mu.Unlock()
	rec, exists := s.inferenceReceipts[jobID]
	if !exists {
		return false, ErrNotFound
	}
	if rec.State != InferenceReceiptPending {
		// A completion is immutable once terminal. Identical retries and
		// conflicting late completions are both no-ops.
		return false, nil
	}
	if err := validateInferenceReceiptLifecycleTime(rec.CreatedAt, completedAt); err != nil {
		return false, err
	}
	if s.inferenceReceiptHashExistsLocked(receiptHash, jobID) {
		return false, ErrInferenceReceiptConflict
	}
	rec.ReceiptHash = receiptHash
	rec.State = InferenceReceiptCompleted
	rec.Envelope = envelope
	rec.UpdatedAt = completedAt
	rec.ExpiresAt = expiresAt
	s.inferenceReceipts[jobID] = rec
	return true, nil
}

func (s *MemoryStore) SetInferenceReceiptState(ctx context.Context, jobID, state string, updatedAt time.Time) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if strings.TrimSpace(jobID) == "" {
		return errors.New("store: inference receipt job ID is required")
	}
	if state != InferenceReceiptFailed && state != InferenceReceiptInterrupted {
		return errors.New("store: inference receipt state can only be failed or interrupted")
	}
	if updatedAt.IsZero() {
		return errors.New("store: inference receipt updated_at is required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	rec, exists := s.inferenceReceipts[jobID]
	if !exists {
		return ErrNotFound
	}
	if rec.State != InferenceReceiptPending {
		return nil
	}
	if err := validateInferenceReceiptLifecycleTime(rec.CreatedAt, updatedAt); err != nil {
		return err
	}
	rec.State = state
	rec.UpdatedAt = updatedAt
	s.inferenceReceipts[jobID] = rec
	return nil
}

func (s *MemoryStore) GetInferenceReceiptByJobID(ctx context.Context, jobID string) (InferenceReceiptRecord, error) {
	if err := ctx.Err(); err != nil {
		return InferenceReceiptRecord{}, err
	}
	if strings.TrimSpace(jobID) == "" {
		return InferenceReceiptRecord{}, ErrNotFound
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	rec, exists := s.inferenceReceipts[jobID]
	if !exists {
		return InferenceReceiptRecord{}, ErrNotFound
	}
	return cloneInferenceReceipt(rec), nil
}

func (s *MemoryStore) GetInferenceReceiptByHash(ctx context.Context, receiptHash string) (InferenceReceiptRecord, error) {
	if err := ctx.Err(); err != nil {
		return InferenceReceiptRecord{}, err
	}
	if strings.TrimSpace(receiptHash) == "" {
		return InferenceReceiptRecord{}, ErrNotFound
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	now := time.Now().UTC()
	for _, rec := range s.inferenceReceipts {
		if rec.State == InferenceReceiptCompleted && rec.ReceiptHash == receiptHash && rec.ExpiresAt.After(now) {
			return cloneInferenceReceipt(rec), nil
		}
	}
	return InferenceReceiptRecord{}, ErrNotFound
}

func (s *MemoryStore) InterruptStaleInferenceReceipts(ctx context.Context, staleBefore, interruptedAt time.Time, limit int) (int, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	if interruptedAt.IsZero() {
		return 0, errors.New("store: inference receipt interruption time is required")
	}
	limit = inferenceReceiptLimit(limit)
	if limit == 0 {
		return 0, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	jobIDs := make([]string, 0)
	for jobID, rec := range s.inferenceReceipts {
		if rec.State == InferenceReceiptPending && !rec.CreatedAt.After(staleBefore) {
			jobIDs = append(jobIDs, jobID)
		}
	}
	sort.Slice(jobIDs, func(i, j int) bool {
		left, right := s.inferenceReceipts[jobIDs[i]], s.inferenceReceipts[jobIDs[j]]
		if left.CreatedAt.Equal(right.CreatedAt) {
			return jobIDs[i] < jobIDs[j]
		}
		return left.CreatedAt.Before(right.CreatedAt)
	})
	if len(jobIDs) > limit {
		jobIDs = jobIDs[:limit]
	}
	for _, jobID := range jobIDs {
		if err := validateInferenceReceiptLifecycleTime(s.inferenceReceipts[jobID].CreatedAt, interruptedAt); err != nil {
			return 0, err
		}
	}
	for _, jobID := range jobIDs {
		rec := s.inferenceReceipts[jobID]
		rec.State = InferenceReceiptInterrupted
		rec.UpdatedAt = interruptedAt
		s.inferenceReceipts[jobID] = rec
	}
	return len(jobIDs), nil
}

func (s *MemoryStore) PruneInferenceReceipts(ctx context.Context, before time.Time, limit int) (int, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	limit = inferenceReceiptLimit(limit)
	if limit == 0 {
		return 0, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	ids := make([]string, 0)
	for jobID, rec := range s.inferenceReceipts {
		if (rec.State == InferenceReceiptPending || inferenceReceiptTerminal(rec.State)) && !rec.ExpiresAt.After(before) {
			ids = append(ids, jobID)
		}
	}
	sort.Slice(ids, func(i, j int) bool {
		left, right := s.inferenceReceipts[ids[i]], s.inferenceReceipts[ids[j]]
		if left.ExpiresAt.Equal(right.ExpiresAt) {
			return ids[i] < ids[j]
		}
		return left.ExpiresAt.Before(right.ExpiresAt)
	})
	if len(ids) > limit {
		ids = ids[:limit]
	}
	for _, jobID := range ids {
		delete(s.inferenceReceipts, jobID)
	}
	return len(ids), nil
}

func (s *MemoryStore) inferenceReceiptHashExistsLocked(receiptHash, exceptJobID string) bool {
	for jobID, rec := range s.inferenceReceipts {
		if jobID != exceptJobID && rec.ReceiptHash == receiptHash && receiptHash != "" {
			return true
		}
	}
	return false
}

func (s *MemoryStore) inferenceReceiptNonceExistsLocked(nonce, exceptJobID string) bool {
	for jobID, rec := range s.inferenceReceipts {
		if jobID != exceptJobID && rec.Nonce == nonce {
			return true
		}
	}
	return false
}
