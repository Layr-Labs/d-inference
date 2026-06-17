package registry

import "time"

// MarkFirstChunkArrived stamps Timing.FirstChunkAt to now exactly once, under
// timingMu. The dispatch goroutine calls this when the first inference chunk
// (incl. held boilerplate) arrives, so the provider read-loop goroutine can read
// the value via FirstChunkAtSafe without a data race.
func (pr *PendingRequest) MarkFirstChunkArrived() {
	if pr == nil || pr.Timing == nil {
		return
	}
	pr.timingMu.Lock()
	if pr.Timing.FirstChunkAt.IsZero() {
		pr.Timing.FirstChunkAt = time.Now()
	}
	pr.timingMu.Unlock()
}

// FirstChunkAtSafe returns Timing.FirstChunkAt under timingMu. It is the only
// safe way for a goroutine other than the request owner (e.g. the provider
// read-loop running handleComplete) to read FirstChunkAt.
func (pr *PendingRequest) FirstChunkAtSafe() time.Time {
	if pr == nil || pr.Timing == nil {
		return time.Time{}
	}
	pr.timingMu.Lock()
	defer pr.timingMu.Unlock()
	return pr.Timing.FirstChunkAt
}
