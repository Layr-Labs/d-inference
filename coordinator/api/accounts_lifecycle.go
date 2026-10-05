package api

import "context"

// StartAccountErasureLoop scrubs pending account erasures whose grace period
// has ended; the erasure owner runs the loop.
func (s *Server) StartAccountErasureLoop(ctx context.Context) {
	s.erasure.StartLoop(ctx)
}
