package registry

import (
	"strings"
	"time"
)

// ModelEvidenceCoverage is the per-model shadow→enforce acceptance record:
// Routable counts providers passing every routing gate EXCEPT the evidence
// gate for that catalog-allowed model; WithEvidence counts the subset also
// holding generation-current application evidence. Enforcement is safe for a
// model only when WithEvidence ≈ Routable.
type ModelEvidenceCoverage struct {
	Routable     int `json:"routable"`
	WithEvidence int `json:"with_evidence"`
}

// ApplicationEvidenceModelCoverage computes ModelEvidenceCoverage for every
// catalog-allowed model advertised by a connected provider, using the same
// liveness surface as public capacity with the evidence gate bypassed — so the
// flip criterion cannot be masked by fleet-wide averages hiding one model
// family's uncovered providers. Thread-safe.
func (r *Registry) ApplicationEvidenceModelCoverage() map[string]ModelEvidenceCoverage {
	now := time.Now()
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make(map[string]ModelEvidenceCoverage)
	for _, p := range r.providers {
		p.mu.Lock()
		baseline := p.Status != StatusOffline && p.Status != StatusUntrusted &&
			!p.PrivateOnly &&
			trustRank(p.TrustLevel) >= trustRank(r.MinTrustLevel) &&
			p.RuntimeVerified &&
			r.providerSupportsPrivateTextModeLocked(p, false) &&
			!p.LastChallengeVerified.IsZero() &&
			now.Sub(p.LastChallengeVerified) <= challengeFreshnessMaxAge
		holds := baseline && r.providerHoldsCurrentApplicationEvidenceLocked(p)
		if baseline {
			for _, model := range p.Models {
				if !r.providerModelAllowedByCatalogLocked(p, model) {
					continue
				}
				coverage := out[model.ID]
				coverage.Routable++
				if holds {
					coverage.WithEvidence++
				}
				out[model.ID] = coverage
			}
		}
		p.mu.Unlock()
	}
	return out
}

// CountProvidersWithCurrentApplicationEvidence returns (holding, connected):
// how many currently connected providers hold generation-current application
// evidence, and the total connected count. This is the shadow-mode acceptance
// instrument: enforcement must not be enabled until holding is near connected.
// Thread-safe.
func (r *Registry) CountProvidersWithCurrentApplicationEvidence() (int, int) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	holding := 0
	for _, provider := range r.providers {
		// Evidence and token fields are written under p.mu by challenge and
		// APNs handlers that do not hold r.mu; lock each provider so this
		// flip-criterion counter never reads a torn record.
		provider.mu.Lock()
		holds := r.providerHoldsCurrentApplicationEvidenceLocked(provider)
		provider.mu.Unlock()
		if holds {
			holding++
		}
	}
	return holding, len(r.providers)
}

// CountProvidersByBinaryHash returns the number of currently connected
// providers whose registration or current, connection-bound application
// evidence attests the given provider binary hash. Used by release
// administration to avoid removing a hash from the forced allowlist while
// old-but-still-connected providers are draining/restarting into a newer
// release.
func (r *Registry) CountProvidersByBinaryHash(hash string) int {
	normalized := strings.ToLower(strings.TrimSpace(hash))
	if normalized == "" {
		return 0
	}

	r.mu.RLock()
	defer r.mu.RUnlock()

	count := 0
	for _, p := range r.providers {
		p.mu.Lock()
		if p.Status == StatusOffline {
			p.mu.Unlock()
			continue
		}

		registrationMatches := p.AttestationResult != nil &&
			strings.EqualFold(p.AttestationResult.BinaryHash, normalized)
		evidence := p.ApplicationEvidence
		evidenceCurrent := evidence.EvidenceGeneration != 0 &&
			(!r.releasePolicyRequired || evidence.PolicyGeneration == r.releasePolicyGeneration) &&
			evidence.ProcessPublicKey == p.PublicKey &&
			evidence.APNsToken == p.APNsDeviceToken
		if evidenceCurrent && p.AttestationResult != nil {
			evidenceCurrent = evidence.SEPublicKey == p.AttestationResult.PublicKey &&
				evidence.Serial == p.AttestationResult.SerialNumber
		}
		evidenceMatches := evidenceCurrent && strings.EqualFold(evidence.BinaryHash, normalized)
		p.mu.Unlock()

		if registrationMatches || evidenceMatches {
			count++
		}
	}
	return count
}

// OnlineCount returns the number of online providers.
func (r *Registry) OnlineCount() int64 {
	return r.onlineCount.Load()
}

// CodeAttestationCoverage reports how many currently online (non-offline,
// non-untrusted) providers have passed APNs code-identity attestation, plus the
// online total. Operators watch this during the grace window to judge when it is
// safe to let the APNS_ENFORCE_AFTER deadline pass — after which every
// un-attested provider (incl. all headless / pre-0.6.0 boxes) is derouted.
// Thread-safe.
func (r *Registry) CodeAttestationCoverage() (codeAttested, online int) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		p.mu.Lock()
		if p.Status != StatusOffline && p.Status != StatusUntrusted {
			online++
			if p.CodeAttested {
				codeAttested++
			}
		}
		p.mu.Unlock()
	}
	return codeAttested, online
}

func (r *Registry) ProviderCount() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.providers)
}

func (r *Registry) ProviderCountByVersion() map[string]int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	counts := make(map[string]int)
	for _, p := range r.providers {
		p.mu.Lock()
		online := p.Status != StatusOffline && p.Status != StatusUntrusted
		p.mu.Unlock()
		if !online {
			continue
		}
		ver := p.Version
		if ver == "" {
			ver = "unknown"
		}
		counts[ver]++
	}
	return counts
}

// TrustStatusCount is one bucket of the fleet trust-state gauge.
type TrustStatusCount struct {
	TrustLevel string
	Status     string
	Count      int
}

// ProviderCountByTrustStatus buckets every connected provider by
// (trust_level, status) so the coordinator can alert on a growing
// self_signed/untrusted cohort. Offline providers are excluded (they are not a
// live routability problem). Unlike most gauges this includes untrusted, since
// the untrusted cohort is exactly what we want visibility into.
func (r *Registry) ProviderCountByTrustStatus() []TrustStatusCount {
	r.mu.RLock()
	defer r.mu.RUnlock()
	type key struct{ trust, status string }
	counts := make(map[key]int)
	for _, p := range r.providers {
		p.mu.Lock()
		status := p.Status
		trust := p.TrustLevel
		p.mu.Unlock()
		if status == StatusOffline {
			continue
		}
		counts[key{string(trust), string(status)}]++
	}
	out := make([]TrustStatusCount, 0, len(counts))
	for k, n := range counts {
		out = append(out, TrustStatusCount{TrustLevel: k.trust, Status: k.status, Count: n})
	}
	return out
}

// ProviderCountByMDMFailure buckets connected, non-hardware providers by their
// last MDM verification failure reason (device-not-found, found-not-enrolled,
// securityinfo-timeout, posture-mismatch, error). This is the stuck-cohort
// breakdown: it distinguishes "never enrolled" from "enrolled but the live
// SecurityInfo check is timing out" so an operator knows whether the problem is
// provider-side enrollment or APNs/MDM delivery. Hardware providers (reason
// cleared) are excluded.
func (r *Registry) ProviderCountByMDMFailure() map[string]int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	counts := make(map[string]int)
	for _, p := range r.providers {
		p.mu.Lock()
		status := p.Status
		trust := p.TrustLevel
		reason := p.MDMFailureReason
		p.mu.Unlock()
		if status == StatusOffline || trust == TrustHardware {
			continue
		}
		if reason == "" {
			reason = "pending"
		}
		counts[reason]++
	}
	return counts
}

// FleetSnapshot is the read-only summary used by metrics polling. We
// don't lock individual providers — counts may be off-by-one under
// heavy churn — that's acceptable for gauges.
type FleetSnapshot struct {
	Connected  int
	Idle       int
	QueueDepth int
}

// Snapshot returns aggregate counts for /metrics gauges. Cheap enough
// to call every few seconds. Takes the registry's read lock for the
// outer iteration AND each provider's mutex briefly to read Status and
// pending count — those fields are written under p.mu elsewhere
// (Heartbeat, AddPending, RemovePending), so reading them without
// p.mu is a data race even if the gauge value is only advisory.
func (r *Registry) Snapshot() FleetSnapshot {
	r.mu.RLock()
	defer r.mu.RUnlock()
	idle := 0
	for _, p := range r.providers {
		p.mu.Lock()
		isIdle := p.Status == StatusOnline && len(p.pendingReqs) == 0
		p.mu.Unlock()
		if isIdle {
			idle++
		}
	}
	q := 0
	if r.queue != nil {
		q = r.queue.TotalSize()
	}
	return FleetSnapshot{
		Connected:  len(r.providers),
		Idle:       idle,
		QueueDepth: q,
	}
}
