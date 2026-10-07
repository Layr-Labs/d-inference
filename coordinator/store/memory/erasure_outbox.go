package memory

import (
	"context"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *MemoryStore) LeaseDueErasureOutbox(ctx context.Context, dueBefore, now time.Time, lease time.Duration, limit int) ([]store.ErasureOutboxWork, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var due []int
	for i, o := range s.erasureOutbox {
		r := s.erasureRequests[o.RequestID]
		if r == nil || r.State != store.ErasureErased {
			continue
		}
		if o.State == store.ErasureOutboxPending && !o.NextAt.After(dueBefore) && !s.erasureOutboxLease[o.ID].After(now) {
			due = append(due, i)
		}
	}
	sort.Slice(due, func(a, b int) bool { return s.erasureOutbox[due[a]].NextAt.Before(s.erasureOutbox[due[b]].NextAt) })
	out := []store.ErasureOutboxWork{}
	for _, i := range due {
		if len(out) == limit {
			break
		}
		s.erasureOutbox[i].LeaseGeneration++
		o := s.erasureOutbox[i]
		s.erasureOutboxLease[o.ID] = now.Add(lease)
		w := store.ErasureOutboxWork{ErasureOutboxItem: o}
		if r := s.erasureRequests[o.RequestID]; r != nil {
			w.AccountID = r.AccountID
			if r.ErasedAt != nil {
				w.ErasedAt = *r.ErasedAt
			}
		}
		out = append(out, w)
	}
	return out, nil
}

func (s *MemoryStore) SaveErasureOutboxResult(ctx context.Context, id string, r store.ErasureOutboxResult) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.erasureOutbox {
		o := &s.erasureOutbox[i]
		if o.ID != id {
			continue
		}
		if o.State != store.ErasureOutboxPending || o.LeaseGeneration != r.LeaseGeneration || !s.erasureOutboxLease[id].After(time.Now()) {
			return store.ErrErasureConflict
		}
		o.State, o.Attempts, o.NextAt, o.LastError, o.StripeJobID = r.State, r.Attempts, r.NextAt, r.LastError, r.StripeJobID
		o.ExternalID, o.JobStatus, o.JobStatusSince, o.JobGeneration = r.ExternalID, r.JobStatus, r.JobStatusSince, r.JobGeneration
		o.DoneAt = nil
		if r.State == store.ErasureOutboxDone {
			at := r.NextAt
			o.ExternalID, o.StripeJobID, o.DoneAt = "", "", &at
		}
		o.HasExternalID, o.HasStripeJob = o.ExternalID != "", o.StripeJobID != ""
		delete(s.erasureOutboxLease, id)
		if r.Split != nil {
			split := *r.Split
			split.State, split.Attempts, split.NextAt, split.CreatedAt = store.ErasureOutboxManualAction, 1, r.NextAt, r.NextAt
			split.HasExternalID = split.ExternalID != ""
			s.erasureOutbox = append(s.erasureOutbox, split)
		}
		return nil
	}
	return store.ErrErasureConflict
}
