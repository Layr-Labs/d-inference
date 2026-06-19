package api

import "context"

func (s *Server) acquireProviderRegisterSlot(ctx context.Context) (func(), bool) {
	if s.providerRegisterSem == nil {
		return func() {}, true
	}

	select {
	case s.providerRegisterSem <- struct{}{}:
		return func() { <-s.providerRegisterSem }, true
	case <-ctx.Done():
		return nil, false
	}
}

func (s *Server) runProviderVerifyWork(ctx context.Context, name string, fn func()) bool {
	if s.providerVerifySem == nil {
		fn()
		return true
	}

	select {
	case s.providerVerifySem <- struct{}{}:
		defer func() { <-s.providerVerifySem }()
	case <-ctx.Done():
		return false
	}

	s.ddIncr("provider.verify_work_started", []string{"kind:" + name})
	fn()
	return true
}
