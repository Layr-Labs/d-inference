package registry

import (
	"container/heap"
	"crypto/rand"
	"encoding/base64"
	"math"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func newCacheReceiptNonce() (string, error) {
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(nonce[:]), nil
}

// PrepareCacheAttempt creates the provider-visible opaque scope and nonce only
// for protocol-v1 providers whose advertised weight hash matches the catalog.
// Protocol-0 providers instead receive an encrypted-body-only, unique cache
// buster so old code cannot derive a caller-controlled remote namespace.
func (r *Registry) PrepareCacheAttempt(pr *PendingRequest, provider *Provider) error {
	if r == nil || pr == nil || provider == nil {
		return nil
	}
	// A PendingRequest can be reused by a queued retry. Never carry cache fields
	// from its previous selected provider into the next attempt.
	r.ForgetCacheAttempt(pr)
	provider.mu.Lock()
	protocolVersion := provider.PrefixCacheProtocol
	providerID := provider.ID
	providerWeightHash := ""
	for _, model := range provider.Models {
		if model.ID == pr.Model {
			providerWeightHash = strings.TrimSpace(model.WeightHash)
			break
		}
	}
	provider.mu.Unlock()
	if protocolVersion < 1 {
		bust, err := newCacheReceiptNonce()
		if err != nil {
			return err
		}
		pr.LegacyCacheBustKey = "darkbloom-uncached-" + bust
		return nil
	}
	if !pr.CacheRoute.present() {
		return nil
	}
	r.mu.RLock()
	tracker := r.cacheRouting
	mode := r.cacheRoutingMode
	expectedHash := ""
	if entry, ok := r.modelCatalog[pr.Model]; ok {
		expectedHash = strings.TrimSpace(entry.WeightHash)
	}
	r.mu.RUnlock()
	if mode == CacheRoutingOff || tracker == nil {
		return nil
	}
	if expectedHash == "" || providerWeightHash == "" || !strings.EqualFold(providerWeightHash, expectedHash) {
		return nil
	}
	scope := r.ProviderCacheScope(pr.ConsumerKey, pr.Model, expectedHash, pr.CacheRoute.ScopeNamespace)
	if scope == "" {
		return nil
	}
	nonce, err := tracker.registerAttempt(pr.RequestID, providerID, pr.Model, pr.CacheRoute, time.Now())
	if err != nil {
		return err
	}
	if nonce == "" {
		return nil
	}
	pr.CacheReceiptNonce = nonce
	pr.CacheScope = scope
	return nil
}

func (r *Registry) ForgetCacheAttempt(pr *PendingRequest) {
	if r == nil || pr == nil {
		return
	}
	r.mu.RLock()
	tracker := r.cacheRouting
	r.mu.RUnlock()
	if tracker != nil {
		tracker.forgetAttempt(pr.CacheReceiptNonce)
	}
	pr.CacheReceiptNonce = ""
	pr.CacheScope = ""
	pr.LegacyCacheBustKey = ""
}

func (r *Registry) ApplyPrefixCacheLookup(providerID string, msg *protocol.PrefixCacheLookupMessage) bool {
	if r == nil {
		return false
	}
	return r.cacheRouting.applyLookup(providerID, msg, time.Now())
}

func (r *Registry) ApplyPrefixCacheReady(providerID string, msg *protocol.PrefixCacheReadyMessage) bool {
	if r == nil {
		return false
	}
	return r.cacheRouting.applyReady(providerID, msg, time.Now())
}

func (t *cacheRoutingTracker) registerAttempt(requestID, providerID, model string, route CacheRoute, now time.Time) (string, error) {
	if t == nil || requestID == "" || providerID == "" || (route.ExactKey == "" && route.ConversationKey == "") {
		return "", nil
	}
	nonce, err := newCacheReceiptNonce()
	if err != nil {
		return "", err
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.sweepIfDueLocked(now)
	if t.nextAttemptSequence == ^uint64(0) {
		// Sequence ordering is process-local and all tracked evidence is
		// ephemeral. Clearing it before the practically unreachable wrap keeps
		// old receipts from becoming indistinguishable from new attempts.
		t.resetLocked(now)
	}
	t.nextAttemptSequence++
	t.storeAttemptLocked(nonce, cacheAttempt{RequestID: requestID, ProviderID: providerID, Model: model, Sequence: t.nextAttemptSequence, ExactKey: route.ExactKey, ConversationKey: route.ConversationKey, CreatedAt: now, ExpiresAt: now.Add(cacheRoutingInFlightAttemptTTL)})
	if len(t.attempts) > t.maxAttempts {
		t.enforceAttemptCapLocked()
	}
	return nonce, nil
}

func (t *cacheRoutingTracker) forgetAttempt(nonce string) {
	if t == nil || nonce == "" {
		return
	}
	t.mu.Lock()
	t.removeAttemptLocked(nonce)
	t.mu.Unlock()
}

func (t *cacheRoutingTracker) markAttemptTerminal(nonce string, now time.Time) {
	if t == nil || nonce == "" {
		return
	}
	t.mu.Lock()
	if attempt, ok := t.activeAttemptLocked(nonce, now); ok {
		attempt.ExpiresAt = now.Add(cacheRoutingAttemptTTL)
		t.attempts[nonce] = attempt
	}
	t.mu.Unlock()
}

func (r *Registry) MarkCacheAttemptTerminal(pr *PendingRequest) {
	if r == nil || pr == nil {
		return
	}
	r.mu.RLock()
	tracker := r.cacheRouting
	r.mu.RUnlock()
	if tracker != nil {
		tracker.markAttemptTerminal(pr.CacheReceiptNonce, time.Now())
	}
}

func validCacheOutcome(outcome string) bool {
	switch outcome {
	case "hit", "miss_absent", "miss_corrupt", "skipped_capacity", "skipped_cost", "skipped_policy":
		return true
	default:
		return false
	}
}

func validCacheTier(tier string) bool {
	switch tier {
	case "", "memory", "ssd":
		return true
	default:
		return false
	}
}

func validReceiptNumbers(cached, saved int, stage float64) bool {
	return cached >= 0 && cached <= cacheRoutingMaxReceiptTokens && saved >= 0 && saved <= cacheRoutingMaxReceiptTokens && stage >= 0 && stage <= cacheRoutingMaxStageMs && !math.IsNaN(stage) && !math.IsInf(stage, 0)
}

func (t *cacheRoutingTracker) applyLookup(providerID string, msg *protocol.PrefixCacheLookupMessage, now time.Time) bool {
	if t == nil || msg == nil || !validCacheOutcome(msg.Outcome) || !validCacheTier(msg.Tier) || !validReceiptNumbers(msg.CachedTokens, msg.PrefillTokensSaved, msg.StageMs) {
		return false
	}
	if msg.Outcome == "hit" && (msg.CachedTokens <= 0 || msg.PrefillTokensSaved <= 0 || msg.PrefillTokensSaved > msg.CachedTokens || msg.Tier == "") {
		return false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.sweepIfDueLocked(now)
	attempt, ok := t.activeAttemptLocked(msg.CacheReceiptNonce, now)
	if !ok || attempt.LookupSeen || attempt.ProviderID != providerID || attempt.RequestID != msg.RequestID {
		return false
	}
	attempt.LookupSeen = true
	t.attempts[msg.CacheReceiptNonce] = attempt
	keys := []string{attempt.ExactKey, attempt.ConversationKey}
	switch msg.Outcome {
	case "hit":
		for _, key := range keys {
			if key == "" {
				continue
			}
			ref := cacheHolderRef{key: key, providerID: providerID}
			if watermark, exists := t.activeWatermarkLocked(ref, now); exists {
				if attempt.Sequence < watermark.Sequence {
					continue
				}
				t.advanceWatermarkLocked(ref, attempt.Sequence, now)
			}
			holder, _ := t.activeHolderLocked(key, providerID, now)
			holder.ProviderID = providerID
			if attempt.Sequence > holder.EvidenceSequence {
				holder.EvidenceSequence = attempt.Sequence
			}
			holder.CachedTokens = msg.CachedTokens
			if msg.PrefillTokensSaved > holder.PrefillTokensSaved {
				holder.PrefillTokensSaved = msg.PrefillTokensSaved
			}
			holder.StageMs = msg.StageMs
			holder.Tier = msg.Tier
			holder.Outcome = msg.Outcome
			holder.Confirmed = true
			holder.UpdatedAt = now
			holder.ExpiresAt = now.Add(t.ttl)
			t.upsertHolderLocked(key, holder)
		}
	case "miss_absent", "miss_corrupt":
		// Early prompt donation may settle before terminal lookup feedback is
		// delivered. A ready receipt from this same attempt is newer, stronger
		// evidence than the lookup miss that preceded the donation.
		if attempt.ReadyTokens > 0 {
			break
		}
		for _, key := range keys {
			if key == "" {
				continue
			}
			ref := cacheHolderRef{key: key, providerID: providerID}
			if watermark, exists := t.activeWatermarkLocked(ref, now); exists && attempt.Sequence < watermark.Sequence {
				continue
			}
			t.advanceWatermarkLocked(ref, attempt.Sequence, now)
			holder, exists := t.activeHolderLocked(key, providerID, now)
			if exists && holder.EvidenceSequence > attempt.Sequence {
				continue
			}
			t.removeHolderLocked(key, providerID)
		}
	case "skipped_capacity":
		// A ready receipt means this attempt subsequently completed a durable
		// donation. That newer, stronger evidence must not be suppressed by its
		// delayed pre-donation capacity feedback.
		if attempt.ReadyTokens > 0 {
			break
		}
		for _, key := range keys {
			if key == "" {
				continue
			}
			ref := cacheHolderRef{key: key, providerID: providerID}
			if watermark, exists := t.activeWatermarkLocked(ref, now); exists && attempt.Sequence < watermark.Sequence {
				continue
			}
			t.advanceWatermarkLocked(ref, attempt.Sequence, now)
			holder, exists := t.activeHolderLocked(key, providerID, now)
			if !exists || holder.EvidenceSequence > attempt.Sequence {
				continue
			}
			holder.SuppressedUntil = now.Add(cacheRoutingCapacitySuppression)
			if attempt.Sequence > holder.EvidenceSequence {
				holder.EvidenceSequence = attempt.Sequence
			}
			holder.Outcome = msg.Outcome
			holder.UpdatedAt = now
			t.upsertHolderLocked(key, holder)
		}
	}
	return true
}

func (t *cacheRoutingTracker) applyReady(providerID string, msg *protocol.PrefixCacheReadyMessage, now time.Time) bool {
	if t == nil || msg == nil || msg.Tier == "" || !validCacheTier(msg.Tier) || !validReceiptNumbers(msg.ReadyTokens, msg.ExpectedPrefillTokensSaved, msg.StageMs) || msg.ReadyTokens <= 0 || msg.RequiredRecomputeTokens < 0 || msg.RequiredRecomputeTokens > cacheRoutingMaxReceiptTokens || msg.ReadyTokens < msg.RequiredRecomputeTokens || msg.ExpectedPrefillTokensSaved != msg.ReadyTokens-msg.RequiredRecomputeTokens {
		return false
	}
	stageMs := msg.StageMs
	if msg.Tier == "ssd" && stageMs == 0 {
		stageMs = cacheRoutingUnmeasuredSSDStageMs
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.sweepIfDueLocked(now)
	attempt, ok := t.activeAttemptLocked(msg.CacheReceiptNonce, now)
	if !ok || attempt.ProviderID != providerID || attempt.RequestID != msg.RequestID {
		return false
	}
	if msg.ReadyTokens <= attempt.ReadyTokens {
		return false
	}
	attempt.ReadyTokens = msg.ReadyTokens
	t.attempts[msg.CacheReceiptNonce] = attempt
	keys := []string{attempt.ExactKey, attempt.ConversationKey}
	for _, key := range keys {
		if key == "" {
			continue
		}
		ref := cacheHolderRef{key: key, providerID: providerID}
		current, currentExists := t.activeHolderLocked(key, providerID, now)
		if current.ProviderID != "" && !now.Before(current.ExpiresAt) {
			t.removeHolderLocked(key, providerID)
			current = cacheHolder{}
			currentExists = false
		}
		watermark, watermarkExists := t.activeWatermarkLocked(ref, now)
		// Physical ready evidence from an older attempt may still extend a live
		// holder's prefix, but it must never recreate a holder removed/suppressed
		// by newer negative evidence.
		if watermarkExists && attempt.Sequence < watermark.Sequence && !currentExists {
			continue
		}
		latestSequence := current.EvidenceSequence
		if watermark.Sequence > latestSequence {
			latestSequence = watermark.Sequence
		}
		authoritativeReady := attempt.Sequence >= latestSequence
		sequenceAdvanced := attempt.Sequence > latestSequence
		if authoritativeReady && watermarkExists {
			t.advanceWatermarkLocked(ref, attempt.Sequence, now)
		}
		if sequenceAdvanced {
			current.EvidenceSequence = attempt.Sequence
		} else if watermark.Sequence > current.EvidenceSequence {
			current.EvidenceSequence = watermark.Sequence
		}
		if authoritativeReady {
			current.SuppressedUntil = time.Time{}
			current.Outcome = "ready"
			current.Confirmed = true
			current.UpdatedAt = now
			current.ExpiresAt = now.Add(t.ttl)
		}
		// Another attempt for this route may already have confirmed a longer
		// prefix. Per-nonce monotonicity is not enough when ready receipts from
		// concurrent attempts interleave.
		if current.ReadyTokens >= msg.ReadyTokens {
			if authoritativeReady && current.ReadyTokens == msg.ReadyTokens {
				current.RequiredRecomputeTokens = msg.RequiredRecomputeTokens
				current.PrefillTokensSaved = msg.ExpectedPrefillTokensSaved
				current.StageMs = stageMs
				current.Tier = msg.Tier
			}
			if authoritativeReady || sequenceAdvanced {
				t.upsertHolderLocked(key, current)
			}
			continue
		}
		current.ProviderID = providerID
		if attempt.Sequence > current.EvidenceSequence {
			current.EvidenceSequence = attempt.Sequence
		}
		current.ReadyTokens = msg.ReadyTokens
		current.RequiredRecomputeTokens = msg.RequiredRecomputeTokens
		current.PrefillTokensSaved = msg.ExpectedPrefillTokensSaved
		current.StageMs = stageMs
		current.Tier = msg.Tier
		current.Outcome = "ready"
		current.Confirmed = true
		current.UpdatedAt = now
		current.ExpiresAt = now.Add(t.ttl)
		t.upsertHolderLocked(key, current)
		if !authoritativeReady && watermarkExists {
			t.advanceWatermarkLocked(ref, watermark.Sequence, now)
		}
	}
	return true
}

func (t *cacheRoutingTracker) resetLocked(now time.Time) {
	t.holderCount = 0
	t.lastSweep = now
	t.holders = make(map[string]map[string]cacheHolder)
	t.attempts = make(map[string]cacheAttempt)
	t.holderOrder = nil
	t.holderOrderByRef = make(map[cacheHolderRef]*cacheHolderOrderEntry)
	t.attemptOrder = nil
	t.attemptOrderByNonce = make(map[string]*cacheAttemptOrderEntry)
	t.watermarks = make(map[cacheHolderRef]cacheEvidenceWatermark)
	t.watermarkOrder = nil
	t.watermarkOrderByRef = make(map[cacheHolderRef]*cacheWatermarkOrderEntry)
	t.activeAttemptRefs = make(map[cacheHolderRef]*cacheActiveAttemptRefState)
	t.nextAttemptSequence = 0
}

func (t *cacheRoutingTracker) disconnect(providerID string) {
	if t == nil || providerID == "" {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	for key, holders := range t.holders {
		if _, exists := holders[providerID]; exists {
			t.removeHolderLocked(key, providerID)
		}
	}
	for nonce, attempt := range t.attempts {
		if attempt.ProviderID == providerID {
			t.removeAttemptLocked(nonce)
		}
	}
	for ref := range t.watermarks {
		if ref.providerID == providerID {
			t.removeWatermarkLocked(ref)
		}
	}
}

func (t *cacheRoutingTracker) storeAttemptLocked(nonce string, attempt cacheAttempt) {
	if previous, exists := t.attempts[nonce]; exists {
		t.removeActiveAttemptRefsLocked(nonce, previous)
	}
	t.attempts[nonce] = attempt
	t.addActiveAttemptRefsLocked(nonce, attempt)
	if entry := t.attemptOrderByNonce[nonce]; entry != nil {
		entry.createdAt = attempt.CreatedAt
		heap.Fix(&t.attemptOrder, entry.index)
		return
	}
	entry := &cacheAttemptOrderEntry{nonce: nonce, createdAt: attempt.CreatedAt}
	heap.Push(&t.attemptOrder, entry)
	t.attemptOrderByNonce[nonce] = entry
}

func (t *cacheRoutingTracker) removeAttemptLocked(nonce string) {
	if attempt, exists := t.attempts[nonce]; exists {
		t.removeActiveAttemptRefsLocked(nonce, attempt)
	}
	delete(t.attempts, nonce)
	if entry := t.attemptOrderByNonce[nonce]; entry != nil {
		heap.Remove(&t.attemptOrder, entry.index)
		delete(t.attemptOrderByNonce, nonce)
	}
}

func (t *cacheRoutingTracker) upsertHolderLocked(key string, holder cacheHolder) {
	if key == "" || holder.ProviderID == "" {
		return
	}
	holders := t.holders[key]
	if holders == nil {
		holders = make(map[string]cacheHolder)
		t.holders[key] = holders
	}
	if _, exists := holders[holder.ProviderID]; !exists {
		t.holderCount++
	}
	holders[holder.ProviderID] = holder
	t.trackHolderOrderLocked(key, holder.ProviderID, holder.UpdatedAt)
	if len(holders) > t.maxHolders {
		oldestProviderID := ""
		var oldestUpdatedAt time.Time
		for providerID, candidate := range holders {
			if oldestProviderID == "" || candidate.UpdatedAt.Before(oldestUpdatedAt) || (candidate.UpdatedAt.Equal(oldestUpdatedAt) && providerID < oldestProviderID) {
				oldestProviderID = providerID
				oldestUpdatedAt = candidate.UpdatedAt
			}
		}
		t.removeHolderLocked(key, oldestProviderID)
	}
	if t.holderCount > t.maxEntries {
		t.enforceCapLocked()
	}
}

func (t *cacheRoutingTracker) activeHolderLocked(key, providerID string, now time.Time) (cacheHolder, bool) {
	holders := t.holders[key]
	holder, exists := holders[providerID]
	if !exists {
		return cacheHolder{}, false
	}
	if now.Before(holder.ExpiresAt) {
		return holder, true
	}
	t.removeHolderLocked(key, providerID)
	return cacheHolder{}, false
}

func (t *cacheRoutingTracker) activeAttemptLocked(nonce string, now time.Time) (cacheAttempt, bool) {
	attempt, exists := t.attempts[nonce]
	if !exists {
		return cacheAttempt{}, false
	}
	if now.Before(attempt.ExpiresAt) {
		return attempt, true
	}
	t.removeAttemptLocked(nonce)
	return cacheAttempt{}, false
}

func (t *cacheRoutingTracker) trackHolderOrderLocked(key, providerID string, updatedAt time.Time) {
	ref := cacheHolderRef{key: key, providerID: providerID}
	if entry := t.holderOrderByRef[ref]; entry != nil {
		entry.updatedAt = updatedAt
		heap.Fix(&t.holderOrder, entry.index)
		return
	}
	entry := &cacheHolderOrderEntry{ref: ref, updatedAt: updatedAt}
	heap.Push(&t.holderOrder, entry)
	t.holderOrderByRef[ref] = entry
}

func (t *cacheRoutingTracker) removeHolderLocked(key, providerID string) {
	ref := cacheHolderRef{key: key, providerID: providerID}
	if holders := t.holders[key]; holders != nil {
		if _, exists := holders[providerID]; exists {
			delete(holders, providerID)
			t.holderCount--
		}
		if len(holders) == 0 {
			delete(t.holders, key)
		}
	}
	if entry := t.holderOrderByRef[ref]; entry != nil {
		heap.Remove(&t.holderOrder, entry.index)
		delete(t.holderOrderByRef, ref)
	}
}

func (t *cacheRoutingTracker) sweepLocked(now time.Time) {
	for key, holders := range t.holders {
		for providerID, holder := range holders {
			if !now.Before(holder.ExpiresAt) {
				t.removeHolderLocked(key, providerID)
			}
		}
	}
	for nonce, attempt := range t.attempts {
		if !now.Before(attempt.ExpiresAt) {
			t.removeAttemptLocked(nonce)
		}
	}
	for ref, watermark := range t.watermarks {
		if !now.Before(watermark.ExpiresAt) {
			t.removeWatermarkLocked(ref)
		}
	}
}

func (t *cacheRoutingTracker) sweepIfDueLocked(now time.Time) {
	if !t.lastSweep.IsZero() && now.Before(t.lastSweep.Add(cacheRoutingSweepInterval)) {
		return
	}
	t.sweepLocked(now)
	t.lastSweep = now
}

func (t *cacheRoutingTracker) enforceCapLocked() {
	for t.holderCount > t.maxEntries {
		oldest := t.holderOrder[0]
		t.removeHolderLocked(oldest.ref.key, oldest.ref.providerID)
	}
}

func (t *cacheRoutingTracker) enforceAttemptCapLocked() {
	for len(t.attempts) > t.maxAttempts {
		t.removeAttemptLocked(t.attemptOrder[0].nonce)
	}
}
