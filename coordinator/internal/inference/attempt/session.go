package attempt

import "context"

// Session owns the admitted request's lifecycle around its attempt loop. The
// completion operation consumes the same loop result used for terminal routing.
type Session struct {
	loop      *Loop
	preflight func()
	finish    func(LoopResult)
	finalize  func()
}

func NewSession(loop *Loop, preflight func(), finish func(LoopResult), finalize func()) *Session {
	return &Session{loop: loop, preflight: preflight, finish: finish, finalize: finalize}
}

func (s *Session) Run(ctx context.Context) LoopResult {
	defer s.finalize()
	s.preflight()
	result := s.loop.Run(ctx)
	if result.Outcome != ClientGone && result.Outcome != ResponseWritten {
		s.finish(result)
	}
	return result
}
