package store

import (
	"context"
	"sort"
	"time"
)

func (s *MemoryStore) UpsertProviderWaitlistSignup(
	ctx context.Context,
	signup ProviderWaitlistSignup,
) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := normalizeAndValidateProviderWaitlistSignup(&signup); err != nil {
		return err
	}

	now := time.Now().UTC()
	if signup.SubmittedAt.IsZero() {
		signup.SubmittedAt = now
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if existing, ok := s.providerWaitlistSignups[signup.Email]; ok {
		signup.CreatedAt = existing.CreatedAt
	} else {
		signup.CreatedAt = now
	}
	signup.UpdatedAt = now
	s.providerWaitlistSignups[signup.Email] = signup
	return nil
}

func (s *MemoryStore) ListProviderWaitlistSignups(
	ctx context.Context,
	limit int,
) ([]ProviderWaitlistSignup, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	limit = providerWaitlistListLimit(limit)

	s.mu.RLock()
	signups := make([]ProviderWaitlistSignup, 0, len(s.providerWaitlistSignups))
	for _, signup := range s.providerWaitlistSignups {
		signups = append(signups, signup)
	}
	s.mu.RUnlock()

	sort.Slice(signups, func(i, j int) bool {
		if signups[i].UpdatedAt.Equal(signups[j].UpdatedAt) {
			return signups[i].Email < signups[j].Email
		}
		return signups[i].UpdatedAt.After(signups[j].UpdatedAt)
	})
	if len(signups) > limit {
		signups = signups[:limit]
	}
	return signups, nil
}
