package testbed

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Backend tags cannot distinguish native from packed live KV. Read the resolved
// precision from the same fixture process, never its requested config or the
// independently selected checkpoint precision.
func (s *Suite) verifyNativeKVPrecision(ctx context.Context, target automaticKVTarget) error {
	registered := s.Coordinator.Registry.GetProvider(target.providerID)
	if registered == nil {
		return fmt.Errorf("provider %s disconnected before live KV precision verification", target.providerID)
	}
	registered.Mu().Lock()
	account := registered.AccountID
	registered.Mu().Unlock()
	registrations := 0
	s.Coordinator.Registry.ForEachProvider(func(p *registry.Provider) {
		p.Mu().Lock()
		if account != "" && p.AccountID == account {
			registrations++
		}
		p.Mu().Unlock()
	})
	if registrations > 1 {
		return fmt.Errorf("provider %s shares an ambiguous fixture account for live KV precision verification", target.providerID)
	}
	var provider *Provider
	for _, handle := range s.Providers {
		if handle != nil && account != "" && handle.AccountID == account {
			if provider != nil {
				return fmt.Errorf("provider %s has multiple fixture handles for live KV precision verification", target.providerID)
			}
			provider = handle
		}
	}
	if provider == nil {
		return fmt.Errorf("provider %s has no account-bound fixture for live KV precision verification", target.providerID)
	}
	pid := 0
	if provider.owned != nil {
		provider.owned.mu.Lock()
		pid = provider.owned.pid
		provider.owned.mu.Unlock()
	} else if provider.cmd != nil {
		pid = provider.cmd.Pid
	}
	if pid <= 1 {
		return fmt.Errorf("provider %s has no started fixture process for live KV precision verification", target.providerID)
	}

	poll := time.NewTicker(250 * time.Millisecond)
	defer poll.Stop()
	logger := s.Logger
	if logger == nil {
		logger = slog.Default()
	}
	last := "provider state not yet reported"
	for {
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("provider %s/%s native live KV precision unverified: %s: %w", target.providerID, target.model, last, err)
		}
		if !provider.Running() {
			return fmt.Errorf("provider %s exited before live KV precision verification", target.providerID)
		}
		raw, err := provider.ReadState(ctx)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("read provider %s state for live KV precision: %w", target.providerID, err)
		}
		if err == nil {
			var state struct {
				PID       int     `json:"pid"`
				WrittenAt float64 `json:"written_at"`
				Slots     []struct {
					Model                    string  `json:"model"`
					KVBackend                string  `json:"kv_backend"`
					KVQuantization           string  `json:"kv_quantization"`
					KVCheckpointQuantization string  `json:"kv_checkpoint_quantization"`
					LoadError                *string `json:"load_error"`
				} `json:"slots"`
			}
			if err := json.Unmarshal(raw, &state); err != nil {
				return fmt.Errorf("decode provider %s state for live KV precision: %w", target.providerID, err)
			}
			if state.PID != pid {
				return fmt.Errorf("provider %s state belongs to pid %d, want fixture pid %d", target.providerID, state.PID, pid)
			}
			now := float64(time.Now().UnixMilli()) / 1000
			if state.WrittenAt <= 0 || state.WrittenAt > now+5 {
				return fmt.Errorf("provider %s state has invalid written_at for live KV precision", target.providerID)
			}
			last = "provider state is stale"
			if now-state.WrittenAt <= 45 {
				index := -1
				for i, slot := range state.Slots {
					if slot.Model == target.model {
						if index != -1 {
							return fmt.Errorf("provider %s has ambiguous state for live KV precision of %s", target.providerID, target.model)
						}
						index = i
					}
				}
				last = "provider state has no matching model slot"
				if index != -1 {
					observation, err := observeRegistrySlot(s.Coordinator.Registry, target.providerID, target.model)
					if err != nil {
						return err
					}
					if !observation.isReady(target.expected) {
						return fmt.Errorf("automatic KV prewarm slot %s/%s lost usable capacity before live KV precision verification", target.providerID, target.model)
					}
					slot := state.Slots[index]
					last = "provider state has no matching resolved backend"
					if slot.KVBackend == observation.backend && slot.LoadError == nil {
						if slot.KVQuantization != "native" {
							return fmt.Errorf("provider %s/%s resolved live kv_quantization=%q, want native (kv_backend=%q); checkpoint precision is independent",
								target.providerID, target.model, slot.KVQuantization, slot.KVBackend)
						}
						logger.Info("resolved live KV precision verified", "provider_id", target.providerID,
							"model", target.model, "kv_backend", slot.KVBackend,
							"kv_quantization", slot.KVQuantization, "kv_checkpoint_quantization", slot.KVCheckpointQuantization)
						return nil
					}
				}
			}
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("provider %s/%s native live KV precision unverified: %s: %w", target.providerID, target.model, last, ctx.Err())
		case <-poll.C:
		}
	}
}
