package api

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// HandoffContext is the process-lifetime context for mutating background work.
// It is cancelled by BeginHandoff and cannot be replaced or restarted.
func (s *Server) HandoffContext() context.Context {
	if s == nil || s.handoffContext == nil {
		return context.Background()
	}
	return s.handoffContext
}

// StartHandoffTask starts a tracked task with the Server-owned handoff context.
// Registration and the irreversible handoff fence are serialized so a task
// cannot start after BeginHandoff has begun.
func (s *Server) StartHandoffTask(name string, task func(context.Context)) bool {
	if s == nil || task == nil {
		return false
	}
	s.backgroundMu.Lock()
	if s.backgroundClosing || s.processShuttingDown.Load() {
		s.backgroundMu.Unlock()
		return false
	}
	ctx := s.HandoffContext()
	s.backgroundTasks.Add(1)
	s.backgroundTaskCount.Add(1)
	s.backgroundMu.Unlock()
	saferun.Go(s.logger, name, func() {
		defer s.backgroundTasks.Done()
		defer s.backgroundTaskCount.Add(-1)
		task(ctx)
	})
	return true
}

func (s *Server) StartBackgroundTask(name string, task func()) bool {
	if s == nil || task == nil {
		return false
	}
	s.backgroundMu.Lock()
	if s.backgroundClosing || s.processShuttingDown.Load() {
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

// CancelHandoffTasks irreversibly closes task registration and cancels the
// shared context. It does not stop completion or settlement workers.
func (s *Server) CancelHandoffTasks() {
	if s == nil {
		return
	}
	s.backgroundMu.Lock()
	s.backgroundClosing = true
	cancel := s.handoffCancel
	s.backgroundMu.Unlock()
	if cancel != nil {
		cancel()
	}
	if s.routeTelemetry != nil {
		s.routeTelemetry.close()
	}
}

func (s *Server) stopBackgroundTasks() {
	s.CancelHandoffTasks()
}

func (s *Server) WaitForBackgroundTasks(ctx context.Context) bool {
	s.stopBackgroundTasks()
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	backgroundStopped := func() bool {
		telemetryWorkers := int64(0)
		if s.routeTelemetry != nil {
			telemetryWorkers = s.routeTelemetry.workerCount()
		}
		return s.backgroundTaskCount.Load() == 0 &&
			s.registry.BackgroundTaskCount() == 0 &&
			telemetryWorkers == 0
	}
	for {
		if backgroundStopped() {
			return true
		}
		select {
		case <-ctx.Done():
			return backgroundStopped()
		case <-ticker.C:
		}
	}
}
