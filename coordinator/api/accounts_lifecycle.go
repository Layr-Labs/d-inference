package api

import "context"

// StartAccountErasureLoop scrubs pending account erasures whose grace period
// has ended; the erasure owner runs the loop.
func (s *Server) StartAccountErasureLoop(ctx context.Context) {
	s.erasure.StartLoop(ctx)
}

// StartErasureOutboxLoop delivers the erasure outbox: the Stripe deletions
// and the erasure_log record that a scrub queued.
func (s *Server) StartErasureOutboxLoop(ctx context.Context) {
	s.erasure.StartOutboxLoop(ctx)
}
