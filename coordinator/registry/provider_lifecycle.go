package registry

import (
	"context"
	"encoding/base64"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/eviction"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"nhooyr.io/websocket"
)

// DefaultProviderHeartbeatTimeout is the normal serving liveness window.
const DefaultProviderHeartbeatTimeout = 90 * time.Second

// Register adds a new provider to the registry, returning its assigned ID.
// Provider-reported model inventory is preserved even when the current catalog
// denies every model; catalog checks are applied dynamically during routing so
// providers that connect before a model is promoted become routable immediately
// after the catalog is updated.
func (r *Registry) Register(id string, conn *websocket.Conn, msg *protocol.RegisterMessage) *Provider {
	r.mu.RLock()
	existing := r.providers[id]
	r.mu.RUnlock()
	if existing != nil {
		r.logger.Warn("duplicate provider registration ignored", "provider_id", id)
		return existing
	}
	// Clamp provider-reported performance stats used in routing score.
	// Refuse to trust unbounded values — a malicious provider reporting
	// DecodeTPS=1e9 would otherwise starve all other providers.
	if v, changed := capacityvalue.ClampNonNeg(msg.DecodeTPS, capacityvalue.MaxDecodeTPS); changed {
		r.logger.Warn("provider decode_tps out of range, clamping",
			"provider_id", id, "reported", msg.DecodeTPS, "clamped", v)
		msg.DecodeTPS = v
	}
	if v, changed := capacityvalue.ClampNonNeg(msg.PrefillTPS, capacityvalue.MaxPrefillTPS); changed {
		r.logger.Warn("provider prefill_tps out of range, clamping",
			"provider_id", id, "reported", msg.PrefillTPS, "clamped", v)
		msg.PrefillTPS = v
	}
	if v, changed := capacityvalue.ClampNonNeg(msg.Hardware.MemoryBandwidthGBs, capacityvalue.MaxMemoryBandwidthGBs); changed {
		r.logger.Warn("provider memory_bandwidth_gbs out of range, clamping",
			"provider_id", id, "reported", msg.Hardware.MemoryBandwidthGBs, "clamped", v)
		msg.Hardware.MemoryBandwidthGBs = v
	}
	if msg.Hardware.MemoryGB < 0 || msg.Hardware.MemoryGB > capacityvalue.MaxMemoryGB {
		r.logger.Warn("provider memory_gb out of range, clamping",
			"provider_id", id, "reported", msg.Hardware.MemoryGB)
		if msg.Hardware.MemoryGB < 0 {
			msg.Hardware.MemoryGB = 0
		} else {
			msg.Hardware.MemoryGB = capacityvalue.MaxMemoryGB
		}
	}

	autopilotState := r.newAutopilotState(id)
	models := autopilotState.RegisterInventory(msg.Models, msg.AutopilotInventory, msg.ModelAutopilot)
	modelInventory, _ := uniqueProviderModels(models)
	cacheStatuses, cacheStatusReported := sanitizePrefixCacheStatuses(
		msg.PrefixCacheStatuses, modelInventory)
	cacheDonationOutcomes := sanitizePrefixCacheDonationOutcomes(
		msg.PrefixCacheDonationOutcomes)
	cacheCapabilities := prefixCacheV2CapabilityMap(msg.PrefixCacheV2Models)
	cacheStatuses, cacheStatusReported = reconcilePrefixCacheStatuses(
		msg.PrefixCacheProtocol,
		cacheCapabilities,
		cacheStatuses,
		cacheStatusReported,
	)

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
		drain:                       r.newProviderDrain(id),
		serviceRetirement:           r.newServiceRetirement(id),
		modelMembership:             r.newModelMembership(id),
		performanceProfiles:         r.performanceProfiles,
		deadlineProfiles:            r.deadlineProfiles,
		deadlinePosture:             r.newDeadlinePosture(id),
		firstContentMeasurements:    r.newMeasurementHistory(id),
		transport:                   r.newTransportHistory(id),
		kvBackends:                  r.newKVBackendHistory(id),
		ModelAutopilot:              autopilot.CloneState(msg.ModelAutopilot),
		ID:                          id,
		persistence:                 ProviderPersistence{pending: r.store != nil},
		Hardware:                    msg.Hardware,
		Models:                      models,
		autopilotState:              autopilotState,
		capacitySamples:             r.newCapacitySamples(id),
		Backend:                     msg.Backend,
		appAttestProtocol:           msg.AppAttestProtocol,
		ReportedRuntimeCapabilities: normalizeRuntimeCapabilities(msg.RuntimeCapabilities, msg.Hardware),
		RuntimeCapabilities:         nil,
		PublicKey:                   pubKey,
		EncryptedResponseChunks:     msg.EncryptedResponseChunks,
		PrivateOnly:                 msg.PrivateOnly,
		APNsDeviceToken:             msg.APNsDeviceToken,
		APNsEnvironment:             msg.APNsEnvironment,
		PrefillTPS:                  msg.PrefillTPS,
		DecodeTPS:                   msg.DecodeTPS,
		PrefixCacheProtocol:         msg.PrefixCacheProtocol,
		prefixCacheRevision:         r.newCacheRevision(id),
		PrefixCacheV2Models:         cacheCapabilities,
		PrefixCacheMemoryModels:     prefixCacheV2CapabilityMap(msg.PrefixCacheMemoryModels),
		PrefixCacheStatuses:         cacheStatuses,
		PrefixCacheStatusReported:   cacheStatusReported,
		PrefixCacheDonationOutcomes: cacheDonationOutcomes,
		ToolConstraintProtocol:      msg.ToolConstraintProtocol,
		ToolConstraintModels:        toolConstraintModelSet(msg.ToolConstraintModels, models),
		TrustLevel:                  TrustNone,
		RuntimeVerified:             true,  // default to verified; API layer sets false when manifest check fails
		RuntimeManifestChecked:      true,  // default to true; API layer sets false when no manifest is configured
		ChallengeVerifiedSIP:        false, // starts false; set true by attestation challenge handler after SIP check
		PrivacyCapabilities:         msg.PrivacyCapabilities,
		TemplateHashes:              CloneStringMap(msg.TemplateHashes),
		Status:                      StatusOnline,
		Conn:                        conn,
		writer:                      r.connections.Open(id, conn),
		warmWork:                    r.newWarmHistory(id),
		warmLoads:                   r.newWarmLifecycle(id),
		LastHeartbeat:               time.Now(),
		connectionOrigin:            r.newConnectionOrigin(id, time.Now()),
		Reputation:                  NewReputation(),
		pendingReqs:                 make(map[string]*PendingRequest),
		applicationProofSettled:     make(chan struct{}),
		challengeKick:               make(chan struct{}, 1),
		registry:                    r,
	}
	r.providerPersistenceFor(p)
	r.bindServiceReservations(p)
	if r.modelCommandFactory != nil {
		p.modelCommands = r.modelCommandFactory(id, providerModelCommandTransport{provider: p})
	}

	r.mu.Lock()
	if existing, exists := r.providers[id]; exists {
		// A connection identity owns exactly one Provider state. Returning the
		// original object keeps capabilities, counters, and pending state stable
		// if an accidental second registration reaches this defense.
		r.mu.Unlock()
		r.logger.Warn("duplicate provider registration ignored", "provider_id", id)
		return existing
	}
	r.providerDirectory.storeLocked(id, p)
	r.attachSessionGate(p)
	p.mu.Lock()
	r.modelIndex.sync(p)
	p.mu.Unlock()
	r.onlineCount.Add(1)
	for _, m := range models {
		r.modelProviderInc(m.ID)
	}
	// Fault-tracking state (breakers, cooldowns) is deliberately NOT cleared
	// here: it is keyed by stable identity and re-attaches when attestation
	// binds this session id (SetAttestationResult → bindStableFaultKey). The
	// old register-time clear was the reconnect exploit — a churning zombie
	// wiped its record every session.
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

	// Registration carries the provider's cache capabilities; bind any rows
	// restored from the durable copy for its epochs (cache_persistence.go).
	r.bindRegisteredProvider(p)
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
// from competing for the same MLX-Swift backend on the host.
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
		)
		// Disconnect closes the socket itself.
		r.Disconnect(id)
	}
}

// RemoveProviderBySerial reports whether any currently-connected provider
// matches the identity (serial OR session id) and, if force is set, evicts them
// from the in-memory map. The DELETE endpoint calls it first with force=false
// to detect an online box (→409), then after the persisted record is purged it
// may call with force=true to drop a lingering in-memory entry so an evict-race
// can't re-persist. Returns true if a matching provider was connected.
func (r *Registry) RemoveProviderBySerial(serialOrID string, force bool) (online bool) {
	if serialOrID == "" {
		return false
	}

	var matched []string
	r.mu.RLock()
	for id, p := range r.providers {
		match := id == serialOrID
		if !match {
			// AttestationResult is written under p.mu (SetAttestationResult), so
			// read it through the thread-safe accessor — this loop holds only the
			// registry lock, not the per-provider one.
			if ar := p.GetAttestationResult(); ar != nil && ar.SerialNumber == serialOrID {
				match = true
			}
		}
		if match {
			matched = append(matched, id)
			// Presence in the map means a live WebSocket connection; treat it as
			// online regardless of routing status (an untrusted-but-connected box
			// would still re-register and re-persist).
			online = true
		}
	}
	r.mu.RUnlock()

	if force {
		// Disconnect takes r.mu itself — call OUTSIDE the RLock above to avoid a
		// self-deadlock (same pattern as DisconnectDuplicatesBySerial).
		for _, id := range matched {
			r.Disconnect(id)
		}
	}
	return online
}

// Disconnect removes a provider from the registry and cleans up pending
// requests. This is the ABRUPT path: the flushed terminals carry
// CoordinatorCauseProviderDisconnected and strike the provider's stable
// identity. The provider read loop, which knows how the socket ended, calls
// DisconnectWithReason (disconnect_reason.go) so a graceful peer close flushes
// with the health-neutral restart cause instead.
func (r *Registry) Disconnect(id string) {
	r.disconnectWithCause(id, protocol.CoordinatorCauseProviderDisconnected)
}

// disconnectWithCause preserves the read loop's graceful/abrupt classification
// for unconditional disconnects. Eviction adds an identity/freshness guard.
func (r *Registry) disconnectWithCause(id string, cause protocol.CoordinatorInferenceErrorCause) {
	r.connectionLifecycle.Disconnect(id, nil, 0, cause)
}

// SetProviderIdle updates a provider's status after a request completes.
// If pending count reaches zero, status goes back to online. If there are
// queued requests and the provider has concurrency headroom, the next
// queued request is assigned immediately.
func (r *Registry) SetProviderIdle(id string) {
	r.mu.RLock()
	p, ok := r.providers[id]
	r.mu.RUnlock()
	if !ok {
		return
	}

	p.mu.Lock()
	if p.pendingCount() == 0 && p.Status != StatusUntrusted && p.Status != StatusOffline {
		p.Status = StatusOnline
	}
	p.mu.Unlock()

	// Use all newly available capacity, not just a single queued request.
	r.drainQueuedRequestsForModelsWithReason(providerModelIDs(p), DrainTriggerIdle)
}

// StartEvictionLoop starts a background goroutine that removes providers
// that haven't sent a heartbeat within the given timeout. It stops when
// the context is cancelled.
func (r *Registry) StartEvictionLoop(ctx context.Context, timeout time.Duration) {
	ticker := time.NewTicker(timeout / 3)
	saferun.Go(r.logger, "registry.evictionLoop", func() {
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				r.connectionLifecycle.Sweep(timeout)
			}
		}
	})
}

// Sweep scans liveness, carries one grace strike, then revalidates each stale
// session atomically with removal. A single maintenance loop owns its cadence.
func (l *ConnectionLifecycle) Sweep(timeout time.Duration) {
	r := l.registry
	now := time.Now()

	// Scan under the READ lock: the walk only reads LastHeartbeat (under p.mu)
	// and the previous sweep's strikes. evictionGrace is written solely by this
	// function on the single eviction goroutine, so a read-scan followed by a
	// short write-locked install is race-free — and the routing scans that
	// share r.mu are no longer blocked for a whole fleet walk every timeout/3.
	// Collect every provider's heartbeat age for the summary, and decide who to
	// evict: a provider is reaped only after it is stale on TWO consecutive
	// sweeps (strike >= 2), so a single transient stall that ages many
	// timestamps at once gives the fleet a sweep to recover instead of a mass
	// reap.
	r.mu.RLock()
	fleet := len(r.providers)
	ages := make([]time.Duration, 0, fleet)
	nextStrikes := r.evictionGrace.Begin() // allocated lazily: steady state carries nothing
	var toEvict []*Provider
	var evictAges []time.Duration
	for id, p := range r.providers {
		p.mu.Lock()
		lastHeartbeat := p.LastHeartbeat
		p.mu.Unlock()
		age := now.Sub(lastHeartbeat)
		ages = append(ages, age)
		if age > timeout {
			strikes := nextStrikes.ObserveStale(id)
			if strikes >= eviction.Threshold {
				toEvict = append(toEvict, p)
				evictAges = append(evictAges, age)
			}
		}
	}
	hadStrikes := r.evictionGrace.Count() > 0
	r.mu.RUnlock()

	// Install the rebuilt strike map under the write lock only when it changes
	// anything (a strike carried or cleared). The steady state — nobody stale,
	// nothing carried — never takes the write lock at all.
	if hadStrikes || nextStrikes.Count() > 0 {
		r.mu.Lock()
		r.evictionGrace.Commit(nextStrikes)
		r.mu.Unlock()
	}

	if len(ages) > 0 {
		amin, amed, ap90, amax := eviction.DurationStats(ages)
		// A tight evicted-age spread (emax-emin small) means many providers went
		// stale at the same instant — a coordinator-side stall. A broad spread
		// means independent provider sleeps. The summary makes that diagnosable.
		emin, _, _, emax := eviction.DurationStats(evictAges)
		r.logger.Info("eviction sweep",
			"fleet", fleet,
			"evicting", len(toEvict),
			"hb_age_min_s", int(amin.Seconds()),
			"hb_age_p50_s", int(amed.Seconds()),
			"hb_age_p90_s", int(ap90.Seconds()),
			"hb_age_max_s", int(amax.Seconds()),
			"evicted_age_min_s", int(emin.Seconds()),
			"evicted_age_max_s", int(emax.Seconds()),
		)
	}

	for _, p := range toEvict {
		// A heartbeat may recover this session after the read scan, or the
		// same id may name a replacement. Revalidate inside the removal lock.
		if r.connectionLifecycle.Disconnect(p.ID, p, timeout, protocol.CoordinatorCauseProviderDisconnected) {
			r.logger.Warn("evicted stale provider", "provider_id", p.ID, "timeout", timeout)
		}
	}

	// Bound the per-identity gate index on the same cadence (gate_state.go):
	// prunes dead per-model entries and drops gates no live session references
	// once idle. Off the request path and outside r.mu.
	r.sweepGates(now)
}
