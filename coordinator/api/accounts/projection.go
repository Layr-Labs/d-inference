package accounts

import (
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// buildMyProvider merges a persisted record with the live registry snapshot.
// Either may be nil (a never-connected stored record OR a fresh registration
// that hasn't been persisted yet), but at least one must be non-nil.
func buildMyProvider(rec *store.ProviderRecord, live *registry.Provider) myProvider {
	mp := myProvider{Status: "never_seen"}

	// 1. Start from the persisted record (covers offline machines).
	if rec != nil {
		mp.ID = rec.ID
		mp.AccountID = rec.AccountID
		mp.Backend = rec.Backend
		mp.Version = rec.Version
		mp.serialNumber = rec.SerialNumber
		mp.TrustLevel = rec.TrustLevel
		mp.Attested = rec.Attested
		mp.MDAVerified = rec.MDAVerified
		mp.SEPublicKey = rec.SEPublicKey
		// X25519 E2E key from the persisted record so OFFLINE machines still
		// resolve per-node earnings. The live branch below overrides
		// it with live.PublicKey when the machine is currently connected.
		mp.ProviderKey = rec.PublicKey
		mp.RuntimeVerified = rec.RuntimeVerified
		mp.LastChallengeVerified = rec.LastChallengeVerified
		mp.FailedChallenges = rec.FailedChallenges
		mp.LifetimeRequestsServed = rec.LifetimeRequestsServed
		mp.LifetimeTokensGenerated = rec.LifetimeTokensGenerated
		if !rec.RegisteredAt.IsZero() {
			t := rec.RegisteredAt
			mp.RegisteredAt = &t
		}
		if !rec.LastSeen.IsZero() {
			t := rec.LastSeen
			mp.LastSeen = &t
		}
		// Decode embedded JSON blobs.
		if len(rec.Hardware) > 0 {
			_ = json.Unmarshal(rec.Hardware, &mp.Hardware)
		}
		if len(rec.Models) > 0 {
			_ = json.Unmarshal(rec.Models, &mp.Models)
		}
		// AttestationResult holds chip name, SE flags, OS security, system
		// volume hash, etc. Source of truth when we don't have a live snapshot.
		if len(rec.AttestationResult) > 0 {
			var ar attestation.VerificationResult
			if err := json.Unmarshal(rec.AttestationResult, &ar); err == nil {
				mp.OSVersion = ar.OSVersion
				if ar.SerialNumber != "" {
					mp.serialNumber = ar.SerialNumber
				}
				if ar.PublicKey != "" {
					mp.SEPublicKey = ar.PublicKey
				}
				mp.SecureEnclave = ar.SecureEnclaveAvailable
				mp.SIPEnabled = ar.SIPEnabled
				mp.SecureBootEnabled = ar.SecureBootEnabled
				mp.AuthenticatedRoot = ar.AuthenticatedRootEnabled
				mp.SystemVolumeHash = ar.SystemVolumeHash
			}
		}
		// Default to offline; will be overwritten below if we have a live snapshot.
		mp.Status = "offline"
	}

	// 2. Overlay the live snapshot if present.
	if live != nil {
		live.Mu().Lock()
		mp.ID = live.ID
		if live.AccountID != "" {
			mp.AccountID = live.AccountID
		}
		mp.Status = string(live.Status)
		mp.Online = live.Status != registry.StatusOffline && live.Status != registry.StatusUntrusted
		hb := live.LastHeartbeat
		if !hb.IsZero() {
			mp.LastHeartbeat = &hb
		}
		// Hardware / models from the live snapshot are authoritative because
		// the provider may have re-registered with new specs.
		mp.Hardware = live.Hardware
		mp.Models = live.ServingModelsLocked()
		if live.CapacityModelIDs != nil {
			ids := append([]string{}, live.CapacityModelIDs...)
			mp.CapacityModelIDs = &ids
		}
		mp.Backend = live.Backend
		mp.Version = live.Version
		mp.OSVersion = "" // A live connection must not inherit a previous OS report.
		mp.TrustLevel = string(live.TrustLevel)
		mp.Attested = live.Attested
		mp.MDAVerified = live.MDAVerified
		mp.SEKeyBound = live.SEKeyBound
		mp.RuntimeVerified = live.RuntimeVerified
		if !live.LastChallengeVerified.IsZero() {
			t := live.LastChallengeVerified
			mp.LastChallengeVerified = &t
		}
		mp.FailedChallenges = live.FailedChallenges
		// X25519 E2E key — the earnings table is keyed on this. Persisted on the
		// record too, so offline machines resolve earnings; the live
		// value is authoritative when connected.
		if live.PublicKey != "" {
			mp.ProviderKey = live.PublicKey
		}
		mp.LifetimeRequestsServed = live.Stats.RequestsServed
		mp.LifetimeTokensGenerated = live.Stats.TokensGenerated
		mp.PrefillTPS = live.PrefillTPS
		mp.DecodeTPS = live.DecodeTPS

		if live.AttestationResult != nil {
			ar := live.AttestationResult
			mp.OSVersion = ar.OSVersion
			if ar.SerialNumber != "" {
				mp.serialNumber = ar.SerialNumber
			}
			if ar.PublicKey != "" {
				mp.SEPublicKey = ar.PublicKey
			}
			mp.SecureEnclave = ar.SecureEnclaveAvailable
			mp.SIPEnabled = ar.SIPEnabled
			mp.SecureBootEnabled = ar.SecureBootEnabled
			mp.AuthenticatedRoot = ar.AuthenticatedRootEnabled
			mp.SystemVolumeHash = ar.SystemVolumeHash
		}
		if live.MDAResult != nil {
			mp.MDAOSVersion = live.MDAResult.OSVersion
			mp.MDASEPVersion = live.MDAResult.SepOSVersion
		}
		// Live system metrics & backend capacity.
		sm := live.SystemMetrics
		mp.SystemMetrics = &sm
		if live.BackendCapacity != nil {
			cap := *live.BackendCapacity
			mp.BackendCapacity = &cap
			if !live.CapacityAcceptedAt.IsZero() {
				acceptedAt := live.CapacityAcceptedAt
				mp.CapacityAcceptedAt = &acceptedAt
			}
		}
		if live.IdleUnloadMins != nil {
			v := *live.IdleUnloadMins
			mp.IdleUnloadMins = &v
		}
		mp.WarmModels = append([]string{}, live.WarmModels...)
		mp.ModelAutopilot = autopilot.CloneState(live.ModelAutopilot)
		mp.CurrentModel = live.CurrentModel
		// Reputation snapshot.
		mp.Reputation = myReputation{
			TotalJobs:          live.Reputation.TotalJobs,
			SuccessfulJobs:     live.Reputation.SuccessfulJobs,
			FailedJobs:         live.Reputation.FailedJobs,
			TotalUptimeSeconds: int64(live.Reputation.TotalUptime / time.Second),
			AvgResponseTimeMs:  int64(live.Reputation.AvgResponseTime / time.Millisecond),
			ChallengesPassed:   live.Reputation.ChallengesPassed,
			ChallengesFailed:   live.Reputation.ChallengesFailed,
		}
		live.Mu().Unlock()
		// Concurrency limit lookup acquires its own lock.
		mp.PendingRequests = live.PendingCount()
		mp.MaxConcurrency = live.MaxConcurrency()
	}

	return mp
}
