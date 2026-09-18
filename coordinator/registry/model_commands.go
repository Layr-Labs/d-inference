package registry

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// SendLoadModel instructs a provider to eagerly load a model so it becomes
// warm for incoming requests. The provider will autonomously evict idle
// models to make room. This is a fire-and-forget call — the coordinator
// does not block waiting for the load to complete. The provider replies
// asynchronously with a load_model_status message.
func (r *Registry) SendLoadModel(providerID, modelID string) error {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	if !ok {
		r.mu.RUnlock()
		return fmt.Errorf("provider %q not found", providerID)
	}
	p.mu.Lock()
	eligible := r.providerServesCatalogModelLocked(p, modelID)
	p.mu.Unlock()
	r.mu.RUnlock()
	if !eligible {
		return fmt.Errorf(
			"provider %q does not satisfy requirements for model %q", providerID, modelID)
	}
	if r.loadModelSender != nil {
		if err := r.loadModelSender(providerID, modelID); err != nil {
			return err
		}
		r.logger.Info("sent load_model to provider", "provider_id", providerID, "model_id", modelID)
		return nil
	}

	msg := protocol.LoadModelMessage{
		Type:    protocol.TypeLoadModel,
		ModelID: modelID,
	}
	data, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("failed to marshal load_model message: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), providerControlWriteTimeout)
	defer cancel()
	if err := p.WriteText(ctx, data); err != nil {
		return fmt.Errorf("failed to send load_model to provider %q: %w", providerID, err)
	}

	r.logger.Info("sent load_model to provider",
		"provider_id", providerID,
		"model_id", modelID,
	)
	return nil
}

// SendPrefetchModel instructs a provider to download + verify a model build
// in the background without loading it into GPU memory. It mirrors
// SendLoadModel but carries no expectation that the model becomes warm; the
// provider replies asynchronously with prefetch_model_status messages and
// re-advertises the build once it is verified on disk. It is the download-only
// primitive a provider's declarative reconciler uses internally to pre-stage a
// desired build before the hard-swap; the coordinator no longer drives a
// weighted migration with it.
func (r *Registry) SendPrefetchModel(providerID, modelID string, priority int) error {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	if !ok {
		r.mu.RUnlock()
		return fmt.Errorf("provider %q not found", providerID)
	}
	p.mu.Lock()
	eligible := r.providerCanAcquireCatalogModelLocked(p, modelID)
	p.mu.Unlock()
	r.mu.RUnlock()
	if !eligible {
		return fmt.Errorf(
			"provider %q does not satisfy requirements for model %q", providerID, modelID)
	}
	if r.prefetchModelSender != nil {
		return r.prefetchModelSender(providerID, modelID, priority)
	}

	msg := protocol.PrefetchModelMessage{
		Type:     protocol.TypePrefetchModel,
		ModelID:  modelID,
		Priority: priority,
	}
	data, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("failed to marshal prefetch_model message: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), providerControlWriteTimeout)
	defer cancel()
	if err := p.WriteText(ctx, data); err != nil {
		return fmt.Errorf("failed to send prefetch_model to provider %q: %w", providerID, err)
	}

	r.logger.Info("sent prefetch_model to provider",
		"provider_id", providerID,
		"model_id", modelID,
		"priority", priority,
	)
	return nil
}

// SendDesiredModels tells a provider, declaratively, the desired build per
// public alias it should converge to (plus the still-acceptable previous build).
// The provider reconciles on its own: background-prefetch any missing desired
// build, then hard-swap (advertise new, drop old) once verified. Mirrors
// SendPrefetchModel — fire-and-forget over the provider's WebSocket.
//
// An EMPTY entries set is still sent ("nothing is desired"): the provider's
// reconcile treats any build it was previously converging to but that is absent
// from the latest set as stale, so an alias delete/repoint that leaves a
// provider with no remaining entries MUST reach it — otherwise an in-flight
// prefetch for the removed alias would complete and hard-swap anyway. Callers
// MUST gate this on backend == mlx-swift AND a provider version that
// understands desired_models, because a pre-feature provider's strict decoder
// throws on unknown message types.
func (r *Registry) SendDesiredModels(providerID string, entries []protocol.DesiredModelEntry) error {
	originallyNonEmpty := len(entries) > 0
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return fmt.Errorf("provider %q not found", providerID)
	}

	// Serialize compute → wire write → last-snapshot update per connection.
	// Registry/provider locks are released before I/O; sendMu preserves order so
	// an untrust revoke always lands after any already-started nonempty frame.
	p.desiredModelsSendMu.Lock()
	defer p.desiredModelsSendMu.Unlock()

	r.mu.RLock()
	current, ok := r.providers[providerID]
	if !ok || current != p {
		r.mu.RUnlock()
		return fmt.Errorf("provider %q not found", providerID)
	}
	p.mu.Lock()
	forceEmpty := p.Status == StatusOffline || p.Status == StatusUntrusted
	eligibleEntries := make([]protocol.DesiredModelEntry, 0, len(entries))
	if !forceEmpty {
		for _, entry := range entries {
			if entry.DesiredBuild == "" ||
				!r.providerCanAcquireCatalogModelLocked(p, entry.DesiredBuild) {
				continue
			}
			if entry.PreviousBuild != "" &&
				!r.providerCanAcquireCatalogModelLocked(p, entry.PreviousBuild) {
				entry.PreviousBuild = ""
			}
			eligibleEntries = append(eligibleEntries, entry)
		}
	}
	if !forceEmpty && originallyNonEmpty && len(eligibleEntries) == 0 {
		p.mu.Unlock()
		r.mu.RUnlock()
		return fmt.Errorf(
			"provider %q does not satisfy desired model requirements", providerID)
	}
	entries = eligibleEntries
	if entries == nil {
		entries = []protocol.DesiredModelEntry{}
	}
	if p.desiredModelsSent && desiredModelEntriesEqual(p.lastDesiredModels, entries) {
		p.mu.Unlock()
		r.mu.RUnlock()
		return nil
	}
	p.mu.Unlock()
	r.mu.RUnlock()

	if r.desiredModelsSender != nil {
		if err := r.desiredModelsSender(providerID, entries); err != nil {
			return err
		}
		recordDesiredModelsSent(p, entries)
		return nil
	}

	msg := protocol.DesiredModelsMessage{
		Type:   protocol.TypeDesiredModels,
		Models: entries,
	}
	data, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("failed to marshal desired_models message: %w", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), providerControlWriteTimeout)
	defer cancel()
	if err := p.WriteText(ctx, data); err != nil {
		return fmt.Errorf("failed to send desired_models to provider %q: %w", providerID, err)
	}
	recordDesiredModelsSent(p, entries)
	r.logger.Info("sent desired_models to provider",
		"provider_id", providerID,
		"entries", len(entries),
	)
	return nil
}

func desiredModelEntriesEqual(left, right []protocol.DesiredModelEntry) bool {
	if len(left) != len(right) {
		return false
	}
	for i := range left {
		if left[i] != right[i] {
			return false
		}
	}
	return true
}

func recordDesiredModelsSent(p *Provider, entries []protocol.DesiredModelEntry) {
	p.mu.Lock()
	p.desiredModelsSent = true
	p.lastDesiredModels = append([]protocol.DesiredModelEntry(nil), entries...)
	p.mu.Unlock()
}

// DesiredModelsForProvider builds the desired_models entries to push to a
// provider. Policy (conservative for this release): emit an entry only for
// aliases where the provider ALREADY advertises the desired OR previous build —
// i.e. the provider is already part of this alias's fleet and should converge to
// the desired build. Aliases the provider has never served are not offered (a
// brand-new provider must advertise some member of an alias to be told its
// desired build). An alias with an empty desired build is skipped.
func (r *Registry) DesiredModelsForProvider(providerID string) []protocol.DesiredModelEntry {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p, ok := r.providers[providerID]
	if !ok || len(r.modelAliases) == 0 {
		return nil
	}
	p.mu.Lock()
	if p.Status == StatusOffline || p.Status == StatusUntrusted {
		p.mu.Unlock()
		return []protocol.DesiredModelEntry{}
	}
	advertised := make(map[string]struct{}, len(p.Models))
	for _, m := range p.Models {
		if m.ID != "" {
			advertised[m.ID] = struct{}{}
		}
	}

	var entries []protocol.DesiredModelEntry
	for alias, t := range r.modelAliases {
		if t.OpenRouterOnly || t.Desired == "" {
			continue
		}
		if !r.providerCanAcquireCatalogModelLocked(p, t.Desired) {
			continue
		}

		_, hasDesired := advertised[t.Desired]
		_, hasPrevious := advertised[t.Previous]
		// A provider advertising only a RETIRED member (offline through a
		// retirement, e.g. previous_build cleared at the end of a rollout) is
		// still part of this alias's fleet — without this it would never learn
		// the desired build and serve zero alias traffic until manual action.
		hasRetired := false
		if !hasDesired && !hasPrevious {
			for _, b := range t.Retired {
				if _, ok := advertised[b]; ok {
					hasRetired = true
					break
				}
			}
		}
		if !hasDesired && !(t.Previous != "" && hasPrevious) && !hasRetired {
			continue
		}
		previous := t.Previous
		if previous != "" && !r.providerCanAcquireCatalogModelLocked(p, previous) {
			previous = ""
		}
		entries = append(entries, protocol.DesiredModelEntry{
			ModelName:     alias,
			DesiredBuild:  t.Desired,
			PreviousBuild: previous,
		})
	}
	p.mu.Unlock()
	// Stable ordering keeps the wire output deterministic (and tests simple).
	sort.Slice(entries, func(i, j int) bool { return entries[i].ModelName < entries[j].ModelName })
	return entries
}
