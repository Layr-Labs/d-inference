package api

import (
	"context"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

const (
	providerRestoreTimeout  = 5 * time.Second
	providerRestoreAttempts = 3
	providerRestoreBackoff  = 100 * time.Millisecond
)

// Called only after verifyProviderAttestation has verified the live SE evidence.
// Routing excludes this verified identity while restoration is pending. Retry
// short transient failures inline, before account binding, duplicate eviction,
// and registration completion. A sustained failure is returned to the WebSocket
// handler, which ends this registration so normal reconnect can try again.
func (s *Server) restorePersistedProviderState(ctx context.Context, p *registry.Provider, serial, seKey string) error {
	if s.store == nil || (serial == "" && seKey == "") {
		p.CompleteProviderStateRestore()
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, providerRestoreTimeout)
	defer cancel()
	started := time.Now()
	var err error
	for attempt := 1; attempt <= providerRestoreAttempts; attempt++ {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		err = s.tryRestorePersistedProviderState(ctx, p, serial, seKey)
		if err == nil {
			return nil
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if s.registry.GetProvider(p.ID) != p {
			return context.Canceled
		}
		if attempt < providerRestoreAttempts {
			timer := time.NewTimer(time.Duration(attempt) * providerRestoreBackoff)
			select {
			case <-ctx.Done():
				timer.Stop()
				return ctx.Err()
			case <-timer.C:
			}
		}
	}
	s.logger.Warn("provider state restore failed; registration must reconnect", "provider_id", p.ID,
		"duration_ms", time.Since(started).Milliseconds(), "error", err)
	return fmt.Errorf("provider state restore: %w", err)
}

func (s *Server) tryRestorePersistedProviderState(ctx context.Context, p *registry.Provider, serial, seKey string) error {
	excluded := s.registry.ProviderIDs()
	for ctx.Err() == nil {
		if s.registry.GetProvider(p.ID) != p {
			return context.Canceled
		}
		rec, err := s.store.GetProviderForRestore(ctx, serial, seKey, excluded)
		if err != nil {
			return err
		}
		if rec != nil && s.registry.GetProvider(rec.ID) != nil {
			// A session may register after the exclusion snapshot. Retry without it;
			// no registry lock is held over database IO or reputation restoration.
			excluded = append(excluded, rec.ID)
			continue
		}
		if rec != nil {
			if err := s.registry.RestoreProviderStateContext(ctx, p, rec); err != nil {
				return err
			}
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if s.registry.GetProvider(p.ID) != p {
			return context.Canceled
		}
		p.CompleteProviderStateRestore()
		return nil
	}
	return ctx.Err()
}
