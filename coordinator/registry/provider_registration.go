package registry

import (
	"context"
	"encoding/base64"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"nhooyr.io/websocket"
)

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
		ID:                          id,
		stateRestorePending:         r.store != nil,
		Hardware:                    msg.Hardware,
		Models:                      models,
		Backend:                     msg.Backend,
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
		PrefixCacheV2Models:         cacheCapabilities,
		PrefixCacheMemoryModels:     prefixCacheV2CapabilityMap(msg.PrefixCacheMemoryModels),
		PrefixCacheStatuses:         cacheStatuses,
		PrefixCacheStatusReported:   cacheStatusReported,
		PrefixCacheDonationOutcomes: cacheDonationOutcomes,
		ToolConstraintProtocol:      msg.ToolConstraintProtocol,
		ToolConstraintModels:        toolConstraintModelSet(msg.ToolConstraintModels, msg.Models),
		TrustLevel:                  TrustNone,
		RuntimeVerified:             true,  // default to verified; API layer sets false when manifest check fails
		RuntimeManifestChecked:      true,  // default to true; API layer sets false when no manifest is configured
		ChallengeVerifiedSIP:        false, // starts false; set true by attestation challenge handler after SIP check
		PrivacyCapabilities:         msg.PrivacyCapabilities,
		TemplateHashes:              CloneStringMap(msg.TemplateHashes),
		Status:                      StatusOnline,
		Conn:                        conn,
		writer:                      newProviderWriter(conn),
		LastHeartbeat:               time.Now(),
		Reputation:                  NewReputation(),
		pendingReqs:                 make(map[string]*PendingRequest),
		applicationProofSettled:     make(chan struct{}),
		challengeKick:               make(chan struct{}, 1),
		registry:                    r,
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
	r.providers[id] = p
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
