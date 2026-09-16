package memory

import (
	"context"
	"errors"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func verificationJobKey(seKey string, kind contracts.VerificationTaskKind) string {
	return seKey + "\x00" + string(kind)
}

func cloneVerificationJob(rec contracts.VerificationJob) contracts.VerificationJob {
	if rec.ClaimExpiresAt != nil {
		expiry := *rec.ClaimExpiresAt
		rec.ClaimExpiresAt = &expiry
	}
	return rec
}

func (s *Store) UpsertVerificationJob(_ context.Context, rec contracts.VerificationJob) (contracts.VerificationJob, error) {
	if rec.SEPubKey == "" || rec.Kind == "" {
		return contracts.VerificationJob{}, errors.New("store: verification job requires SE key and kind")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	key := verificationJobKey(rec.SEPubKey, rec.Kind)
	current, exists := s.verificationJobs[key]
	if exists && current.State != contracts.VerificationStateCompleted {
		current.Serial = rec.Serial
		if rec.UDID != "" {
			current.UDID = rec.UDID
		}
		if rec.Priority < current.Priority {
			current.Priority = rec.Priority
		}
		if current.State == contracts.VerificationStateWaitingChallenge &&
			rec.State == contracts.VerificationStatePending {
			current.State = contracts.VerificationStatePending
			current.NextAttemptAt = rec.NextAttemptAt
		}
		if current.State == contracts.VerificationStateRunning &&
			rec.State == contracts.VerificationStatePending {
			current.ReopenPending = true
			current.NextAttemptAt = rec.NextAttemptAt
		}
		current.UpdatedAt = rec.UpdatedAt
		s.verificationJobs[key] = current
		return cloneVerificationJob(current), nil
	}
	if rec.LastOutcome == "" {
		rec.LastOutcome = contracts.VerificationOutcomeNone
	}
	rec.ReopenPending = false
	rec.ClaimOwner = ""
	rec.ClaimExpiresAt = nil
	s.verificationJobs[key] = cloneVerificationJob(rec)
	return cloneVerificationJob(rec), nil
}

func (s *Store) GetVerificationJob(_ context.Context, seKey string, kind contracts.VerificationTaskKind) (*contracts.VerificationJob, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rec, ok := s.verificationJobs[verificationJobKey(seKey, kind)]
	if !ok {
		return nil, nil
	}
	copy := cloneVerificationJob(rec)
	return &copy, nil
}

func (s *Store) ListDueVerificationJobs(
	ctx context.Context,
	now time.Time,
	limit int,
) ([]contracts.VerificationJob, error) {
	return s.ListDueVerificationJobsPage(ctx, now, limit, 0)
}

func (s *Store) ListDueVerificationJobsPage(
	_ context.Context,
	now time.Time,
	limit, offset int,
) ([]contracts.VerificationJob, error) {
	if limit <= 0 || offset < 0 {
		return nil, nil
	}
	s.mu.RLock()
	out := make([]contracts.VerificationJob, 0, min(limit, len(s.verificationJobs)))
	for _, rec := range s.verificationJobs {
		claimExpired := rec.State == contracts.VerificationStateRunning &&
			rec.ClaimExpiresAt != nil && !rec.ClaimExpiresAt.After(now)
		if rec.State != contracts.VerificationStatePending &&
			rec.State != contracts.VerificationStateBackoff && !claimExpired {
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

func (s *Store) ClaimVerificationJob(_ context.Context, seKey string, kind contracts.VerificationTaskKind, owner string, now, expiresAt time.Time) (contracts.VerificationJob, bool, error) {
	if owner == "" || !expiresAt.After(now) {
		return contracts.VerificationJob{}, false, errors.New("store: invalid verification claim")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	key := verificationJobKey(seKey, kind)
	rec, ok := s.verificationJobs[key]
	claimExpired := ok && rec.State == contracts.VerificationStateRunning &&
		rec.ClaimExpiresAt != nil && !rec.ClaimExpiresAt.After(now)
	if !ok ||
		(rec.State != contracts.VerificationStatePending &&
			rec.State != contracts.VerificationStateBackoff && !claimExpired) ||
		rec.NextAttemptAt.After(now) ||
		(rec.ClaimOwner != "" && rec.ClaimExpiresAt != nil && rec.ClaimExpiresAt.After(now)) {
		return contracts.VerificationJob{}, false, nil
	}
	rec.State = contracts.VerificationStateRunning
	rec.ReopenPending = false
	rec.ClaimOwner = owner
	expiry := expiresAt
	rec.ClaimExpiresAt = &expiry
	rec.UpdatedAt = now
	s.verificationJobs[key] = rec
	return cloneVerificationJob(rec), true, nil
}

func (s *Store) ReleaseVerificationJob(_ context.Context, seKey string, kind contracts.VerificationTaskKind, owner string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := verificationJobKey(seKey, kind)
	rec, ok := s.verificationJobs[key]
	if !ok || rec.ClaimOwner != owner {
		return nil
	}
	rec.State = contracts.VerificationStatePending
	rec.ReopenPending = false
	rec.ClaimOwner = ""
	rec.ClaimExpiresAt = nil
	rec.UpdatedAt = now
	s.verificationJobs[key] = rec
	return nil
}

func (s *Store) CompleteVerificationJob(_ context.Context, seKey string, kind contracts.VerificationTaskKind, owner string, outcome contracts.VerificationOutcome, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := verificationJobKey(seKey, kind)
	rec, ok := s.verificationJobs[key]
	if !ok {
		return nil
	}
	if rec.ClaimOwner != owner {
		return nil
	}
	if rec.ReopenPending {
		rec.State = contracts.VerificationStatePending
		rec.ReopenPending = false
	} else {
		rec.State = contracts.VerificationStateCompleted
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

func (s *Store) RescheduleVerificationJob(_ context.Context, seKey string, kind contracts.VerificationTaskKind, owner string, priority contracts.VerificationPriority, retryStage int, previousDelay time.Duration, nextAttemptAt time.Time, outcome contracts.VerificationOutcome, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := verificationJobKey(seKey, kind)
	rec, ok := s.verificationJobs[key]
	if !ok || rec.ClaimOwner != owner {
		return nil
	}
	if rec.ReopenPending {
		rec.State = contracts.VerificationStatePending
		rec.ReopenPending = false
	} else {
		rec.State = contracts.VerificationStateBackoff
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
