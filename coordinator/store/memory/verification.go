package memory

import (
	"context"
	"errors"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func verificationJobKey(seKey string, kind store.VerificationTaskKind) string {
	return seKey + "\x00" + string(kind)
}

func cloneVerificationJob(rec store.VerificationJob) store.VerificationJob {
	if rec.ClaimExpiresAt != nil {
		expiry := *rec.ClaimExpiresAt
		rec.ClaimExpiresAt = &expiry
	}
	return rec
}

func (s *MemoryStore) UpsertVerificationJob(_ context.Context, rec store.VerificationJob) (store.VerificationJob, error) {
	if rec.SEPubKey == "" || rec.Kind == "" {
		return store.VerificationJob{}, errors.New("store: verification job requires SE key and kind")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.erasedSEOwnerLocked(rec.SEPubKey, "") {
		return store.VerificationJob{}, store.ErrErasureConflict
	}
	key := verificationJobKey(rec.SEPubKey, rec.Kind)
	current, exists := s.verificationJobs[key]
	if exists && current.State != store.VerificationStateCompleted {
		current.Serial = rec.Serial
		if rec.UDID != "" {
			current.UDID = rec.UDID
		}
		if rec.Priority < current.Priority {
			current.Priority = rec.Priority
		}
		if current.State == store.VerificationStateWaitingChallenge &&
			rec.State == store.VerificationStatePending {
			current.State = store.VerificationStatePending
			current.NextAttemptAt = rec.NextAttemptAt
		}
		if current.State == store.VerificationStateRunning &&
			rec.State == store.VerificationStatePending {
			current.ReopenPending = true
			current.NextAttemptAt = rec.NextAttemptAt
		}
		current.UpdatedAt = rec.UpdatedAt
		s.verificationJobs[key] = current
		return cloneVerificationJob(current), nil
	}
	if rec.LastOutcome == "" {
		rec.LastOutcome = store.VerificationOutcomeNone
	}
	rec.ReopenPending = false
	rec.ClaimOwner = ""
	rec.ClaimExpiresAt = nil
	s.verificationJobs[key] = cloneVerificationJob(rec)
	return cloneVerificationJob(rec), nil
}

func (s *MemoryStore) GetVerificationJob(_ context.Context, seKey string, kind store.VerificationTaskKind) (*store.VerificationJob, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rec, ok := s.verificationJobs[verificationJobKey(seKey, kind)]
	if !ok {
		return nil, nil
	}
	copy := cloneVerificationJob(rec)
	return &copy, nil
}

func (s *MemoryStore) ListDueVerificationJobs(
	ctx context.Context,
	now time.Time,
	limit int,
) ([]store.VerificationJob, error) {
	return s.ListDueVerificationJobsPage(ctx, now, limit, 0)
}

func (s *MemoryStore) ListDueVerificationJobsPage(
	_ context.Context,
	now time.Time,
	limit, offset int,
) ([]store.VerificationJob, error) {
	if limit <= 0 || offset < 0 {
		return nil, nil
	}
	s.mu.RLock()
	out := make([]store.VerificationJob, 0, min(limit, len(s.verificationJobs)))
	for _, rec := range s.verificationJobs {
		claimExpired := rec.State == store.VerificationStateRunning &&
			rec.ClaimExpiresAt != nil && !rec.ClaimExpiresAt.After(now)
		if rec.State != store.VerificationStatePending &&
			rec.State != store.VerificationStateBackoff && !claimExpired {
			continue
		}
		if rec.NextAttemptAt.After(now) {
			continue
		}
		if rec.ClaimOwner != "" && rec.ClaimExpiresAt != nil && rec.ClaimExpiresAt.After(now) {
			continue
		}
		out = append(out, cloneVerificationJob(rec))
	}
	s.mu.RUnlock()
	sort.Slice(out, func(i, j int) bool {
		if out[i].Priority != out[j].Priority {
			return out[i].Priority < out[j].Priority
		}
		if !out[i].NextAttemptAt.Equal(out[j].NextAttemptAt) {
			return out[i].NextAttemptAt.Before(out[j].NextAttemptAt)
		}
		if out[i].SEPubKey != out[j].SEPubKey {
			return out[i].SEPubKey < out[j].SEPubKey
		}
		return out[i].Kind < out[j].Kind
	})
	if offset >= len(out) {
		return nil, nil
	}
	end := min(offset+limit, len(out))
	return out[offset:end], nil
}

func (s *MemoryStore) ClaimVerificationJob(_ context.Context, seKey string, kind store.VerificationTaskKind, owner string, now, expiresAt time.Time) (store.VerificationJob, bool, error) {
	if owner == "" || !expiresAt.After(now) {
		return store.VerificationJob{}, false, errors.New("store: invalid verification claim")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	key := verificationJobKey(seKey, kind)
	rec, ok := s.verificationJobs[key]
	claimExpired := ok && rec.State == store.VerificationStateRunning &&
		rec.ClaimExpiresAt != nil && !rec.ClaimExpiresAt.After(now)
	if !ok ||
		(rec.State != store.VerificationStatePending &&
			rec.State != store.VerificationStateBackoff && !claimExpired) ||
		rec.NextAttemptAt.After(now) ||
		(rec.ClaimOwner != "" && rec.ClaimExpiresAt != nil && rec.ClaimExpiresAt.After(now)) {
		return store.VerificationJob{}, false, nil
	}
	rec.State = store.VerificationStateRunning
	rec.ReopenPending = false
	rec.ClaimOwner = owner
	expiry := expiresAt
	rec.ClaimExpiresAt = &expiry
	rec.UpdatedAt = now
	s.verificationJobs[key] = rec
	return cloneVerificationJob(rec), true, nil
}

func (s *MemoryStore) ReleaseVerificationJob(_ context.Context, seKey string, kind store.VerificationTaskKind, owner string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := verificationJobKey(seKey, kind)
	rec, ok := s.verificationJobs[key]
	if !ok || rec.ClaimOwner != owner {
		return nil
	}
	rec.State = store.VerificationStatePending
	rec.ReopenPending = false
	rec.ClaimOwner = ""
	rec.ClaimExpiresAt = nil
	rec.UpdatedAt = now
	s.verificationJobs[key] = rec
	return nil
}

func (s *MemoryStore) CompleteVerificationJob(_ context.Context, seKey string, kind store.VerificationTaskKind, owner string, outcome store.VerificationOutcome, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := verificationJobKey(seKey, kind)
	rec, ok := s.verificationJobs[key]
	if !ok {
		return nil
	}
	if rec.ClaimOwner != "" && rec.ClaimOwner != owner {
		return nil
	}
	if rec.ReopenPending {
		rec.State = store.VerificationStatePending
		rec.ReopenPending = false
	} else {
		rec.State = store.VerificationStateCompleted
		rec.RetryStage = 0
		rec.PreviousDelay = 0
		rec.NextAttemptAt = time.Time{}
		rec.LastOutcome = outcome
	}
	rec.UpdatedAt = now
	rec.ClaimOwner = ""
	rec.ClaimExpiresAt = nil
	s.verificationJobs[key] = rec
	return nil
}

func (s *MemoryStore) RescheduleVerificationJob(_ context.Context, seKey string, kind store.VerificationTaskKind, owner string, priority store.VerificationPriority, retryStage int, previousDelay time.Duration, nextAttemptAt time.Time, outcome store.VerificationOutcome, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := verificationJobKey(seKey, kind)
	rec, ok := s.verificationJobs[key]
	if !ok || rec.ClaimOwner != owner {
		return nil
	}
	if rec.ReopenPending {
		rec.State = store.VerificationStatePending
		rec.ReopenPending = false
	} else {
		rec.State = store.VerificationStateBackoff
		rec.Priority = priority
		rec.RetryStage = retryStage
		rec.PreviousDelay = previousDelay
		rec.NextAttemptAt = nextAttemptAt
		rec.LastOutcome = outcome
	}
	rec.UpdatedAt = now
	rec.ClaimOwner = ""
	rec.ClaimExpiresAt = nil
	s.verificationJobs[key] = rec
	return nil
}
