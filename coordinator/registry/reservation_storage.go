package registry

import "github.com/eigeninference/d-inference/coordinator/internal/registry/candidatearena"

// reservationCandidateStorage has one exclusive borrower, from the first
// private scan through commit, detached decision/plan projection, and retries.
// Public or decorated preparations never receive this storage.
type reservationCandidateStorage struct {
	registry *Registry
	storage  *candidatearena.Storage[routingCandidate]
}

// forScan runs after copying the model index under the existing scan lock.
// Large scans use ordinary request-owned chunks immediately: borrowing, growing,
// clearing, then discarding a pool that cannot retain them adds needless work.
func (s *reservationCandidateStorage) forScan(providers int) *candidatearena.Storage[routingCandidate] {
	if s == nil || providers > candidatearena.MaxReusableCandidates {
		return nil
	}
	if s.storage == nil {
		if cached := s.registry.reservationStorage.Get(); cached != nil {
			s.storage = cached.(*candidatearena.Storage[routingCandidate])
		} else {
			s.storage = &candidatearena.Storage[routingCandidate]{}
		}
	}
	return s.storage
}

func (s *reservationCandidateStorage) reset() {
	if s.storage != nil {
		s.storage.Reset()
	}
}

func (s *reservationCandidateStorage) release() {
	if s.storage != nil {
		s.storage.Reset()
		s.registry.reservationStorage.Put(s.storage)
	}
}
