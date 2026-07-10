package api

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
)

func (s *Server) StartBackgroundTask(name string, task func()) bool {
	if s == nil || task == nil {
		return false
	}
	s.backgroundMu.Lock()
	if s.backgroundClosing {
		s.backgroundMu.Unlock()
		return false
	}
	s.backgroundTasks.Add(1)
	s.backgroundTaskCount.Add(1)
	s.backgroundMu.Unlock()
	saferun.Go(s.logger, name, func() {
		defer s.backgroundTasks.Done()
		defer s.backgroundTaskCount.Add(-1)
		task()
	})
	return true
}

func (s *Server) stopBackgroundTasks() {
	s.backgroundMu.Lock()
	s.backgroundClosing = true
	s.backgroundMu.Unlock()
}

func (s *Server) WaitForBackgroundTasks(ctx context.Context) bool {
	s.stopBackgroundTasks()
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	for {
		if s.backgroundTaskCount.Load() == 0 && s.registry.BackgroundTaskCount() == 0 {
			return true
		}
		select {
		case <-ctx.Done():
			return s.backgroundTaskCount.Load() == 0 && s.registry.BackgroundTaskCount() == 0
		case <-ticker.C:
		}
	}
}
