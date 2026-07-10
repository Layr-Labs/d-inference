package api

import (
	"context"
	"net/http"
	"time"
)

type QuiescenceSnapshot struct {
	HTTPInference         int64 `json:"http_inference"`
	HTTPMutations         int64 `json:"http_mutations"`
	ProviderSessions      int64 `json:"provider_sessions"`
	ProvidersConnected    int   `json:"providers_connected"`
	PendingAttempts       int   `json:"pending_attempts"`
	RequestQueue          int   `json:"request_queue"`
	WriterDataQueue       int   `json:"writer_data_queue"`
	WriterControlQueue    int   `json:"writer_control_queue"`
	WriterActive          int   `json:"writer_active"`
	CompletionQueue       int   `json:"completion_queue"`
	CompletionActive      int64 `json:"completion_active"`
	CompletionOutstanding int64 `json:"completion_outstanding"`
	SettlementHeld        int   `json:"settlement_held"`
	SettlementCallbacks   int   `json:"settlement_callbacks"`
	OwnershipHealthy      bool  `json:"ownership_healthy"`
	TelemetryQueued       int   `json:"telemetry_queued"`
	BackgroundTasks       int64 `json:"background_tasks"`
	Quiescent             bool  `json:"quiescent"`
}

func (s *Server) Quiescence() QuiescenceSnapshot {
	fleet := s.registry.Snapshot()
	held, callbacks := s.settlements.snapshot()
	ownershipHealthy := true
	if lost := s.store.OwnershipLost(); lost != nil {
		select {
		case <-lost:
			ownershipHealthy = false
		default:
		}
	}
	telemetryQueued := 0
	if s.routeTelemetry != nil {
		telemetryQueued = len(s.routeTelemetry.ch)
	}
	snapshot := QuiescenceSnapshot{
		HTTPInference:         s.Inflight(),
		HTTPMutations:         s.MutationInflight(),
		ProviderSessions:      s.providerSessionCount.Load(),
		ProvidersConnected:    fleet.Connected,
		PendingAttempts:       fleet.Pending,
		RequestQueue:          fleet.QueueDepth,
		WriterDataQueue:       fleet.WriterDataDepth,
		WriterControlQueue:    fleet.WriterControlDepth,
		WriterActive:          fleet.WritersActive,
		CompletionQueue:       s.completions.depth(),
		CompletionActive:      s.completions.activeCount(),
		CompletionOutstanding: s.completions.outstandingCount(),
		SettlementHeld:        held,
		SettlementCallbacks:   callbacks,
		OwnershipHealthy:      ownershipHealthy,
		TelemetryQueued:       telemetryQueued,
		BackgroundTasks:       s.backgroundTaskCount.Load() + s.registry.BackgroundTaskCount(),
	}
	snapshot.Quiescent = snapshot.HTTPInference == 0 &&
		snapshot.HTTPMutations == 0 &&
		snapshot.ProviderSessions == 0 &&
		snapshot.ProvidersConnected == 0 &&
		snapshot.PendingAttempts == 0 &&
		snapshot.RequestQueue == 0 &&
		snapshot.WriterDataQueue == 0 &&
		snapshot.WriterControlQueue == 0 &&
		snapshot.WriterActive == 0 &&
		snapshot.CompletionOutstanding == 0 &&
		snapshot.SettlementHeld == 0 &&
		snapshot.SettlementCallbacks == 0 &&
		snapshot.BackgroundTasks == 0 &&
		snapshot.OwnershipHealthy
	return snapshot
}

func (s *Server) WaitForQuiescence(ctx context.Context) bool {
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	for {
		if s.Quiescence().Quiescent {
			return true
		}
		select {
		case <-ctx.Done():
			return s.Quiescence().Quiescent
		case <-ticker.C:
		}
	}
}

func (s *Server) handleAdminQuiescence(w http.ResponseWriter, r *http.Request) {
	// Side-effect-free admin-key authentication is deliberate: requireAuth can
	// provision Privy users, touch API keys, and migrate legacy balances, which
	// would make the act of observing quiescence mutate the system.
	if !s.requireAdminKey(w, r) {
		return
	}
	writeJSON(w, http.StatusOK, s.Quiescence())
}
