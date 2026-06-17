package api

func (s *Server) triggerWarmPool() {
	if s == nil || s.registry == nil {
		return
	}
	s.registry.RequestWarmPoolTrigger()
}

func (s *Server) recordWarmPoolQueueState(model string) {
	if s == nil || s.registry == nil || s.registry.Queue() == nil {
		return
	}
	depth, oldest := s.registry.Queue().QueueStats(model)
	if depth <= 0 {
		s.registry.RecordWarmPoolQueueCleared(model)
		return
	}
	s.registry.RecordWarmPoolQueueEnqueued(model, depth, oldest)
	s.triggerWarmPool()
}
