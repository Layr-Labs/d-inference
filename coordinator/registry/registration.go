package registry

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"nhooyr.io/websocket"
)

// Sanity caps on provider-reported stats. A malicious (or broken) provider
// could otherwise report absurd values to monopolize routing. These caps are
// ~3-4x current hardware ceilings (M2 Ultra is ~800 GB/s, MLX decode is ~120
// tok/s, max Mac Studio RAM is 512 GB) so legitimate future hardware isn't
// clamped unnecessarily.
const (
	maxDecodeTPS                    = 500.0
	maxPrefillTPS                   = 5000.0
	maxMemoryBandwidthGBs           = 2000.0
	maxMemoryGB                     = 1024
	maxMemoryGBFloat                = 1024.0
	maxReportedMaxConcurrency       = 24
	maxTokensPotential              = 1_000_000
	maxTokenBudgetCap         int64 = 10_000_000_000 // 10 billion — generous safety valve for total token budget capacity
	maxModelLoadTimeMS        int64 = 3_600_000      // 1 hour — generous ceiling for a cold-start model load; larger is implausible/garbage
)

// clampNonNeg returns v clamped into [0, max]; NaN/negative become 0.
// The bool is true if the value was out of range.
func clampNonNeg(v, max float64) (float64, bool) {
	if math.IsNaN(v) || v < 0 {
		return 0, true
	}
	if v > max {
		return max, true
	}
	return v, false
}

// clampBackendCapacity applies sanity caps to provider-reported backend
// capacity fields that feed the routing scorer. A provider reporting
// TotalMemoryGB=1e9 would make gpuUtil ~= 0 and dodge health penalties, so
// we cap it at maxMemoryGBFloat. Same for MaxTokensPotential which directly
// controls backlog cost. NaN/negative become 0.
func clampBackendCapacity(logger *slog.Logger, providerID string, bc *protocol.BackendCapacity) {
	if bc == nil {
		return
	}
	if v, changed := clampNonNeg(bc.TotalMemoryGB, maxMemoryGBFloat); changed {
		logger.Warn("provider total_memory_gb out of range, clamping",
			"provider_id", providerID, "reported", bc.TotalMemoryGB, "clamped", v)
		bc.TotalMemoryGB = v
	}
	if v, changed := clampNonNeg(bc.GPUMemoryActiveGB, maxMemoryGBFloat); changed {
		logger.Warn("provider gpu_memory_active_gb out of range, clamping",
			"provider_id", providerID, "reported", bc.GPUMemoryActiveGB, "clamped", v)
		bc.GPUMemoryActiveGB = v
	}
	if v, changed := clampNonNeg(bc.GPUMemoryPeakGB, maxMemoryGBFloat); changed {
		bc.GPUMemoryPeakGB = v
	}
	if v, changed := clampNonNeg(bc.GPUMemoryCacheGB, maxMemoryGBFloat); changed {
		bc.GPUMemoryCacheGB = v
	}
	for i := range bc.Slots {
		s := &bc.Slots[i]
		if s.MaxTokensPotential < 0 || s.MaxTokensPotential > maxTokensPotential {
			logger.Warn("provider slot max_tokens_potential out of range, clamping",
				"provider_id", providerID, "model", s.Model, "reported", s.MaxTokensPotential)
			if s.MaxTokensPotential < 0 {
				s.MaxTokensPotential = 0
			} else {
				s.MaxTokensPotential = maxTokensPotential
			}
		}
		if s.NumRunning < 0 {
			s.NumRunning = 0
		}
		if s.NumWaiting < 0 {
			s.NumWaiting = 0
		}
		if s.MaxConcurrency < 0 || s.MaxConcurrency > maxReportedMaxConcurrency {
			logger.Warn("provider slot max_concurrency out of range, clamping",
				"provider_id", providerID, "model", s.Model, "reported", s.MaxConcurrency)
			if s.MaxConcurrency < 0 {
				s.MaxConcurrency = 0
			} else {
				s.MaxConcurrency = maxReportedMaxConcurrency
			}
		}
		if v, changed := clampNonNeg(s.ObservedDecodeTPS, maxDecodeTPS); changed {
			logger.Warn("provider slot observed_decode_tps out of range, clamping",
				"provider_id", providerID, "model", s.Model, "reported", s.ObservedDecodeTPS, "clamped", v)
			s.ObservedDecodeTPS = v
		}
		// observed_prefill_tps: an out-of-range value (NaN/negative, or absurdly
		// high — a known provider-side overflow when the admitted→first-token
		// window collapses on a prefix-cache hit) is treated as NO measurement (0)
		// rather than clamped to the ceiling. Clamping garbage UP to maxPrefillTPS
		// would make the TTFT estimate over-optimistic (prefill looks instant) and
		// the hard gate over-accept; zeroing it makes resolvePrefillTPS fall back to
		// the conservative decode×ratio estimate until the provider reports a sane
		// value (provider fix: only sample cold prefills).
		if math.IsNaN(s.ObservedPrefillTPS) || s.ObservedPrefillTPS < 0 || s.ObservedPrefillTPS > maxPrefillTPS {
			logger.Warn("provider slot observed_prefill_tps out of range; ignoring (fall back to estimate)",
				"provider_id", providerID, "model", s.Model, "reported", s.ObservedPrefillTPS)
			s.ObservedPrefillTPS = 0
		}
		if s.ModelLoadTimeMS < 0 || s.ModelLoadTimeMS > maxModelLoadTimeMS {
			logger.Warn("provider slot model_load_time_ms out of range, clamping",
				"provider_id", providerID, "model", s.Model, "reported", s.ModelLoadTimeMS)
			if s.ModelLoadTimeMS < 0 {
				s.ModelLoadTimeMS = 0
			} else {
				s.ModelLoadTimeMS = maxModelLoadTimeMS
			}
		}
		if s.ActiveTokenBudgetUsed < 0 || s.ActiveTokenBudgetUsed > maxTokenBudgetCap {
			if s.ActiveTokenBudgetUsed < 0 {
				s.ActiveTokenBudgetUsed = 0
			} else {
				s.ActiveTokenBudgetUsed = maxTokenBudgetCap
			}
		}
		if s.ActiveTokenBudgetMax < 0 || s.ActiveTokenBudgetMax > maxTokenBudgetCap {
			if s.ActiveTokenBudgetMax < 0 {
				s.ActiveTokenBudgetMax = 0
			} else {
				s.ActiveTokenBudgetMax = maxTokenBudgetCap
			}
		}
		if s.QueuedTokenBudget < 0 || s.QueuedTokenBudget > maxTokenBudgetCap {
			if s.QueuedTokenBudget < 0 {
				s.QueuedTokenBudget = 0
			} else {
				s.QueuedTokenBudget = maxTokenBudgetCap
			}
		}
	}
}

// Register adds a new provider to the registry, returning its assigned ID.
// Provider-reported model inventory is preserved even when the current catalog
// denies every model; catalog checks are applied dynamically during routing so
// providers that connect before a model is promoted become routable immediately
// after the catalog is updated.
func (r *Registry) Register(id string, conn *websocket.Conn, msg *protocol.RegisterMessage) *Provider {
	// Clamp provider-reported performance stats used in routing score.
	// Refuse to trust unbounded values — a malicious provider reporting
	// DecodeTPS=1e9 would otherwise starve all other providers.
	if v, changed := clampNonNeg(msg.DecodeTPS, maxDecodeTPS); changed {
		r.logger.Warn("provider decode_tps out of range, clamping",
			"provider_id", id, "reported", msg.DecodeTPS, "clamped", v)
		msg.DecodeTPS = v
	}
	if v, changed := clampNonNeg(msg.PrefillTPS, maxPrefillTPS); changed {
		r.logger.Warn("provider prefill_tps out of range, clamping",
			"provider_id", id, "reported", msg.PrefillTPS, "clamped", v)
		msg.PrefillTPS = v
	}
	if v, changed := clampNonNeg(msg.Hardware.MemoryBandwidthGBs, maxMemoryBandwidthGBs); changed {
		r.logger.Warn("provider memory_bandwidth_gbs out of range, clamping",
			"provider_id", id, "reported", msg.Hardware.MemoryBandwidthGBs, "clamped", v)
		msg.Hardware.MemoryBandwidthGBs = v
	}
	if msg.Hardware.MemoryGB < 0 || msg.Hardware.MemoryGB > maxMemoryGB {
		r.logger.Warn("provider memory_gb out of range, clamping",
			"provider_id", id, "reported", msg.Hardware.MemoryGB)
		if msg.Hardware.MemoryGB < 0 {
			msg.Hardware.MemoryGB = 0
		} else {
			msg.Hardware.MemoryGB = maxMemoryGB
		}
	}

	models := msg.Models

	// Validate X25519 public key if provided.
	// Reject invalid keys at registration rather than failing at encryption time.
	pubKey := msg.PublicKey
	if pubKey != "" {
		decoded, err := base64.StdEncoding.DecodeString(pubKey)
		if err != nil || len(decoded) != 32 {
			r.logger.Warn("provider public key invalid, clearing",
				"provider_id", id,
				"error", "must be 32-byte base64-encoded X25519 key",
			)
			pubKey = "" // clear so provider can register but won't receive encrypted requests
		}
	}

	p := &Provider{
		ID:                      id,
		Hardware:                msg.Hardware,
		Models:                  models,
		Backend:                 msg.Backend,
		PublicKey:               pubKey,
		EncryptedResponseChunks: msg.EncryptedResponseChunks,
		PrivateOnly:             msg.PrivateOnly,
		APNsDeviceToken:         msg.APNsDeviceToken,
		APNsEnvironment:         msg.APNsEnvironment,
		PrefillTPS:              msg.PrefillTPS,
		DecodeTPS:               msg.DecodeTPS,
		TrustLevel:              TrustNone,
		RuntimeVerified:         true,  // default to verified; API layer sets false when manifest check fails
		RuntimeManifestChecked:  true,  // default to true; API layer sets false when no manifest is configured
		ChallengeVerifiedSIP:    false, // starts false; set true by attestation challenge handler after SIP check
		PrivacyCapabilities:     msg.PrivacyCapabilities,
		TemplateHashes:          CloneStringMap(msg.TemplateHashes),
		Status:                  StatusOnline,
		Conn:                    conn,
		LastHeartbeat:           time.Now(),
		Reputation:              NewReputation(),
		pendingReqs:             make(map[string]*PendingRequest),
	}

	r.mu.Lock()
	r.providers[id] = p
	r.onlineCount.Add(1)
	for _, m := range models {
		r.modelProviderInc(m.ID)
	}
	// A (re-)registration means a fresh provider process: any dispatch-time
	// load-failure cool-downs belonged to the previous process's memory state.
	r.clearDispatchLoadCooldownsLocked(id)
	r.mu.Unlock()

	// Open a session row for this connection (async; durable uptime history).
	// serial/account are empty here (set after attestation/linking) and are
	// backfilled by the throttled TouchProviderSession in persistProviderNow.
	if r.store != nil {
		sessionID := p.ID
		saferun.Go(r.logger, "registry.openSession", func() {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := r.store.OpenProviderSession(ctx, sessionID, "", ""); err != nil {
				r.logger.Warn("failed to open provider session", "provider_id", sessionID, "error", err)
			}
		})
	}

	r.logger.Info("provider registered",
		"provider_id", id,
		"chip", msg.Hardware.ChipName,
		"memory_gb", msg.Hardware.MemoryGB,
		"models", len(msg.Models),
		"backend", msg.Backend,
		"prefill_tps", msg.PrefillTPS,
		"decode_tps", msg.DecodeTPS,
	)

	// Persist provider record to store (async).
	r.persistProviderNow(p)

	return p
}

func CloneStringMap(in map[string]string) map[string]string {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]string, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}

// DisconnectDuplicatesBySerial disconnects all providers that share the same
// serial number as the given provider, except the given provider itself.
// This prevents multiple WebSocket connections from the same physical machine
// from competing for the same vllm-mlx backend on localhost.
func (r *Registry) DisconnectDuplicatesBySerial(keepID string, serial string) {
	if serial == "" {
		return
	}

	var toEvict []string

	r.mu.RLock()
	for id, p := range r.providers {
		if id == keepID {
			continue
		}
		if p.AttestationResult != nil && p.AttestationResult.SerialNumber == serial {
			toEvict = append(toEvict, id)
		}
	}
	r.mu.RUnlock()

	for _, id := range toEvict {
		r.logger.Warn("evicting duplicate provider from same device",
			"evicted_id", id,
			"kept_id", keepID,
			"serial", serial,
		)
		// Disconnect closes the socket itself.
		r.Disconnect(id)
	}
}

// Heartbeat updates the provider's status and stats.
func (r *Registry) Heartbeat(id string, msg *protocol.HeartbeatMessage) {
	r.mu.RLock()
	p, ok := r.providers[id]
	r.mu.RUnlock()
	if !ok {
		r.logger.Warn("heartbeat from unknown provider", "provider_id", id)
		return
	}

	// Clamp heartbeat-reported capacity and metrics so a malicious provider
	// can't skew routing by reporting absurd values (e.g. TotalMemoryGB=1e9
	// would drive gpuUtil to 0 and sidestep health penalties).
	clampBackendCapacity(r.logger, id, msg.BackendCapacity)
	if v, changed := clampNonNeg(msg.SystemMetrics.MemoryPressure, 1.0); changed {
		msg.SystemMetrics.MemoryPressure = v
	}
	if v, changed := clampNonNeg(msg.SystemMetrics.CPUUsage, 1.0); changed {
		msg.SystemMetrics.CPUUsage = v
	}

	p.mu.Lock()
	now := time.Now()
	prevHB := p.LastHeartbeat
	p.LastHeartbeat = now
	p.Stats.RequestsServed += cumulativeDelta(p.lastSessionStats.RequestsServed, msg.Stats.RequestsServed)
	p.Stats.TokensGenerated += cumulativeDelta(p.lastSessionStats.TokensGenerated, msg.Stats.TokensGenerated)
	p.lastSessionStats = msg.Stats
	p.SystemMetrics = msg.SystemMetrics
	// Update backend capacity from heartbeat. A nil report clears prior live
	// capacity so stale slot state cannot keep influencing routing.
	p.BackendCapacity = msg.BackendCapacity
	if p.BackendCapacity != nil {
		chipFamily := p.Hardware.ChipFamily
		for _, slot := range p.BackendCapacity.Slots {
			if slot.ObservedDecodeTPS > 0 {
				r.tpsRegistry.Record(slot.Model, chipFamily, slot.ObservedDecodeTPS)
			}
		}
	}
	if !prevHB.IsZero() {
		const maxUptimeCredit = 2 * time.Minute
		if delta := now.Sub(prevHB); delta > 0 && delta <= maxUptimeCredit {
			p.Reputation.RecordUptime(delta)
		}
	}
	// Update warm models from heartbeat. Always overwrite -- an empty list
	// means the provider has no models loaded, and stale entries must be
	// cleared to prevent TriggerModelSwaps from suppressing needed swaps.
	p.WarmModels = msg.WarmModels
	if msg.ActiveModel != nil {
		p.CurrentModel = *msg.ActiveModel
	} else {
		// nil active_model means no model is loaded — clear stale state
		// so attestation challenges don't compare against an unloaded model.
		p.CurrentModel = ""
	}
	// Only update status from heartbeat if provider is not actively serving
	// (serving status is managed by request lifecycle). Crucially, an
	// untrusted provider must NOT transition back to StatusOnline here —
	// that would cause an onlineCount double-decrement when Disconnect
	// later sees StatusOnline and decrements a second time.
	if p.Status == StatusUntrusted {
		// no status transitions allowed
	} else if p.Status != StatusServing || msg.Status == "idle" {
		switch msg.Status {
		case "idle":
			p.Status = StatusOnline
		case "serving":
			p.Status = StatusServing
		}
	}
	p.mu.Unlock()

	r.PersistProviderThrottled(p)
	r.persistReputationThrottled(p)

	// Heartbeats can make a recovered slot routable again (for example after a
	// crash auto-restart). Drain matching queues using the canonical scheduler
	// rather than the legacy direct queue assignment path.
	r.drainQueuedRequestsForModels(providerModelIDs(p))

	// If queue drain didn't satisfy all pending requests (no warm provider),
	// check if a cold provider should swap models to serve queued demand.
	r.TriggerModelSwaps()
}

// SendLoadModel instructs a provider to eagerly load a model so it becomes
// warm for incoming requests. The provider will autonomously evict idle
// models to make room. This is a fire-and-forget call — the coordinator
// does not block waiting for the load to complete. The provider replies
// asynchronously with a load_model_status message.
func (r *Registry) SendLoadModel(providerID, modelID string) error {
	if sender := r.loadModelSenderSnapshot(); sender != nil {
		return sender(providerID, modelID)
	}
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return fmt.Errorf("provider %q not found", providerID)
	}

	msg := protocol.LoadModelMessage{
		Type:    protocol.TypeLoadModel,
		ModelID: modelID,
	}
	data, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("failed to marshal load_model message: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	p.mu.Lock()
	conn := p.Conn
	p.mu.Unlock()

	if conn == nil {
		return fmt.Errorf("provider %q has no active connection", providerID)
	}

	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		return fmt.Errorf("failed to send load_model to provider %q: %w", providerID, err)
	}

	r.logger.Info("sent load_model to provider",
		"provider_id", providerID,
		"model_id", modelID,
	)
	return nil
}

func (r *Registry) SetLoadModelSenderForTest(sender func(providerID, modelID string) error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.loadModelSender = sender
}

func (r *Registry) loadModelSenderSnapshot() func(providerID, modelID string) error {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.loadModelSender
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
	r.mu.RUnlock()
	if !ok {
		return fmt.Errorf("provider %q not found", providerID)
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

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	p.mu.Lock()
	conn := p.Conn
	p.mu.Unlock()

	if conn == nil {
		return fmt.Errorf("provider %q has no active connection", providerID)
	}

	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
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
	if entries == nil {
		// Marshal as "models": [] — the Swift decoder requires an array.
		entries = []protocol.DesiredModelEntry{}
	}
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return fmt.Errorf("provider %q not found", providerID)
	}

	msg := protocol.DesiredModelsMessage{
		Type:   protocol.TypeDesiredModels,
		Models: entries,
	}
	data, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("failed to marshal desired_models message: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	p.mu.Lock()
	conn := p.Conn
	p.mu.Unlock()

	if conn == nil {
		return fmt.Errorf("provider %q has no active connection", providerID)
	}

	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		return fmt.Errorf("failed to send desired_models to provider %q: %w", providerID, err)
	}

	r.logger.Info("sent desired_models to provider",
		"provider_id", providerID,
		"entries", len(entries),
	)
	return nil
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
	advertised := make(map[string]struct{}, len(p.Models))
	for _, m := range p.Models {
		if m.ID != "" {
			advertised[m.ID] = struct{}{}
		}
	}
	p.mu.Unlock()

	var entries []protocol.DesiredModelEntry
	for alias, t := range r.modelAliases {
		if t.Desired == "" {
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
		entries = append(entries, protocol.DesiredModelEntry{
			ModelName:     alias,
			DesiredBuild:  t.Desired,
			PreviousBuild: t.Previous,
		})
	}
	// Stable ordering keeps the wire output deterministic (and tests simple).
	sort.Slice(entries, func(i, j int) bool { return entries[i].ModelName < entries[j].ModelName })
	return entries
}
