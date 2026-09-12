package testbed

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (p *Provider) startOwned(ctx context.Context, relay string, cfg ProviderConfig) error {
	target := *p.Target
	if err := target.validate(); err != nil {
		return err
	}
	if cfg.PrefixCacheMode != "off" && cfg.PrefixCacheMode != "ssd" {
		return fmt.Errorf("owned target requires explicit cache mode")
	}
	if !cfg.EnableEphemeralPrefixCache {
		return fmt.Errorf("owned HTTP fixture requires ephemeral isolated cache mode")
	}
	models := map[string]bool{}
	for _, model := range target.Models {
		models[model.ID] = true
	}
	ids := cfg.ModelIDs
	if len(ids) == 0 {
		ids = []string{cfg.ModelID}
	}
	for _, id := range ids {
		if !models[id] {
			return fmt.Errorf("target lacks exact model input %q", id)
		}
	}
	token, err := os.ReadFile(cfg.AuthTokenPath)
	if err != nil {
		return err
	}
	cfg.AuthTokenPath = ""
	cfg.MTPDrafterPath = target.AssistantPath
	endpoint := relay
	if target.SSH != nil {
		endpoint = "http://127.0.0.1:" + strconv.Itoa(target.SSH.ForwardPort)
	}
	spec, err := buildProviderStartSpec(endpoint, target.Root, cfg, p.ProviderIndex)
	if err != nil {
		return err
	}
	p.owned, err = startOwnedProvider(ctx, target, spec, token, p.suiteNonce, relay, exec.Command)
	return err
}

func (p *Provider) Stop() { _ = p.StopAndWait() }
func (p *Provider) StopAndWait() error {
	if p.owned == nil {
		p.stopLocal()
		return nil
	}
	err := p.owned.stop()
	if err == nil && p.AuthDir != "" {
		_ = os.RemoveAll(p.AuthDir)
	}
	return err
}

// BoundProviders returns explicit targets in declared order. Registration
// order and registry map iteration never identify a physical host.
func (s *Suite) BoundProviders() ([]*registry.Provider, error) {
	var available []*registry.Provider
	s.Coordinator.Registry.ForEachProvider(func(p *registry.Provider) { available = append(available, p) })
	if s.Config.ProviderTargets == nil {
		return available, nil
	}
	byAccount := map[string]*registry.Provider{}
	for _, p := range available {
		p.Mu().Lock()
		account := p.AccountID
		p.Mu().Unlock()
		if byAccount[account] != nil {
			return nil, fmt.Errorf("multiple providers registered for one fixture account")
		}
		byAccount[account] = p
	}
	hosts := map[string]bool{}
	ordered := make([]*registry.Provider, 0, len(s.Providers))
	for _, handle := range s.Providers {
		if handle.owned == nil {
			return nil, fmt.Errorf("target has no owned process")
		}
		handle.owned.mu.Lock()
		host := handle.owned.hostID
		handle.owned.mu.Unlock()
		if host == "" || hosts[host] {
			return nil, fmt.Errorf("targets do not identify distinct physical hosts")
		}
		hosts[host] = true
		p := byAccount[handle.AccountID]
		if p == nil {
			return nil, fmt.Errorf("target %s has no registered account-bound provider", handle.Target.Name)
		}
		ordered = append(ordered, p)
	}
	if len(ordered) != len(s.Config.ProviderTargets) {
		return nil, fmt.Errorf("incomplete target registration")
	}
	return ordered, nil
}

type ProviderHostBinding struct {
	Name       string           `json:"name"`
	AccountID  string           `json:"account_id"`
	ProviderID string           `json:"provider_id"`
	HostID     string           `json:"host_id"`
	PID        int              `json:"pid"`
	Root       string           `json:"root"`
	Entry      HostObservation  `json:"entry"`
	Cleanup    *HostObservation `json:"cleanup,omitempty"`
}

func (s *Suite) HostBindings() ([]ProviderHostBinding, error) {
	if s.Config.ProviderTargets == nil {
		return nil, nil
	}
	providers, err := s.BoundProviders()
	if err != nil {
		return nil, err
	}
	out := make([]ProviderHostBinding, 0, len(providers))
	for i, p := range providers {
		owner := s.Providers[i].owned
		owner.mu.Lock()
		row := ProviderHostBinding{Name: s.Providers[i].Target.Name, AccountID: s.Providers[i].AccountID, ProviderID: p.ID,
			HostID: owner.hostID, PID: owner.pid, Root: s.Providers[i].Target.Root, Entry: owner.entry, Cleanup: owner.cleanup}
		owner.mu.Unlock()
		out = append(out, row)
	}
	return out, nil
}

func (p *Provider) HostCleanup() *HostObservation {
	if p.owned == nil {
		return nil
	}
	p.owned.mu.Lock()
	defer p.owned.mu.Unlock()
	if p.owned.cleanup == nil {
		return nil
	}
	copied := *p.owned.cleanup
	return &copied
}
