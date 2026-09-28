package registry

import (
	"encoding/base64"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestVerifiedPairAppAttestReservesCommitsAndReleasesWithoutLegacyEvidence(t *testing.T) {
	r, p, request, _ := appAttestPairFixture(t)
	h, m := pairTestActive(t, r, p, request)
	if m.TranscriptVersion != 2 || m.TranscriptSHA256 == verifiedPairLegacyTranscript(m) {
		t.Fatal("typed identity reused legacy domain")
	}
	for _, member := range m.Members {
		if member.Identity.Kind != protocol.NativeIdentityAppAttest || member.DeviceSerial != "" || member.SEPublicKey != "" {
			t.Fatal("fabricated MDA identity")
		}
	}
	if _, err := r.ValidateVerifiedPair(h); err != nil {
		t.Fatal(err)
	}
	if err := r.ObserveVerifiedPairOwnerReleased(h, p[0], m.TranscriptSHA256); err != nil {
		t.Fatal(err)
	}
	pairTestRequirePhase(t, r, h, VerifiedPairQuarantined)
	r.mu.RLock()
	held := len(r.verifiedPairs.devices)
	r.mu.RUnlock()
	if held == 0 {
		t.Fatal("unilateral cleanup freed holds")
	}
	if err := r.ObserveVerifiedPairOwnerReleased(h, p[1], m.TranscriptSHA256); err != nil {
		t.Fatal(err)
	}
	pairTestRequirePhase(t, r, h, VerifiedPairReleased)
	r.mu.RLock()
	held = len(r.verifiedPairs.devices)
	r.mu.RUnlock()
	if held != 0 {
		t.Fatal("bilateral cleanup left owned indexes")
	}
}
func TestVerifiedPairAppAttestMixedKindAndLegacyV1RemainDistinct(t *testing.T) {
	r, p, request := pairTestRegistry(t)
	h, m := pairTestReserve(t, r, p, request)
	if m.TranscriptVersion != 1 || m.TranscriptSHA256 != verifiedPairLegacyTranscript(m) {
		t.Fatal("legacy v1 changed")
	}
	r.CancelVerifiedPair(h)
	pairTestAppAttest(t, r, p[1], "machine-b")
	h, m = pairTestActive(t, r, p, request)
	if m.TranscriptVersion != 2 || m.Members[0].Identity.Kind != 0 || m.Members[1].Identity.Kind != protocol.NativeIdentityAppAttest {
		t.Fatal("mixed identity selection")
	}
	if _, err := r.ValidateVerifiedPair(h); err != nil {
		t.Fatal(err)
	}
}
func TestVerifiedPairAppAttestNoFallbackAfterLeaseLoss(t *testing.T) {
	r, p, request := pairTestRegistry(t)
	p[0].mu.Lock()
	legacyRegistration := *p[0].AttestationResult
	legacyEvidence := p[0].ApplicationEvidence
	p[0].mu.Unlock()
	pairTestAppAttest(t, r, p[0], "machine-a")
	pairTestAppAttest(t, r, p[1], "machine-b")
	h, _ := pairTestActive(t, r, p, request)
	p[0].mu.Lock()
	p[0].AttestationResult = &legacyRegistration
	p[0].ApplicationEvidence = legacyEvidence
	p[0].Attested, p[0].MDAVerified, p[0].SEKeyBound = true, true, true
	p[0].CodeAttested, p[0].FreshCodeAttested, p[0].ChallengeVerifiedSIP = true, true, true
	p[0].TrustLevel = TrustHardware
	p[0].LastChallengeVerified = time.Now()
	p[0].mu.Unlock()
	r.mu.RLock()
	p[0].mu.Lock()
	_, err := r.legacyVerifiedPairMemberLocked(p[0], time.Now())
	p[0].mu.Unlock()
	r.mu.RUnlock()
	if err != nil {
		t.Fatal("alternate legacy proof fixture is not valid", err)
	}
	r.ClearAppAttestServingAuthorization(p[0])
	pairTestDone(t, h)
	pairTestRequirePhase(t, r, h, VerifiedPairQuarantined)
	if _, err := r.ValidateVerifiedPair(h); err == nil {
		t.Fatal("AA grant fell back to valid legacy")
	}
}
func TestVerifiedPairAppAttestRefusesMissingRuntimeProofAndSubstitutions(t *testing.T) {
	for _, kind := range []string{"missing-control", "missing-metal", "expired", "signer", "process", "account", "machine", "credential", "proof", "runtime", "heartbeat", "same-machine", "alias-point"} {
		t.Run(kind, func(t *testing.T) {
			r, p, request, _ := appAttestPairFixture(t)
			r.mu.Lock()
			unlock := lockVerifiedPairMembers(p)
			switch kind {
			case "missing-control":
				p[0].appAttestAuthorization.VerifiedControlPublicKey = ""
			case "missing-metal":
				p[0].appAttestAuthorization.VerifiedMetallibHash = ""
			case "expired":
				p[0].appAttestAuthorization.ValidUntil = time.Now()
			case "signer":
				p[0].AttestationResult.PublicKey = p[1].AttestationResult.PublicKey
			case "process":
				p[0].PublicKey = p[1].PublicKey
			case "account":
				p[0].AccountID = "other"
			case "machine":
				p[0].verifiedMachineID = "other"
			case "credential":
				p[0].appAttestAuthorization.CredentialID = ""
			case "proof":
				p[0].appAttestAuthorization.ProofSessionID = ""
			case "runtime":
				p[0].RuntimeManifestChecked = false
			case "heartbeat":
				p[0].LastHeartbeat = time.Now().Add(-verifiedPairHeartbeatLimit)
			case "same-machine":
				p[0].verifiedMachineID = p[1].verifiedMachineID
				p[0].appAttestAuthorization.MachineID = p[1].verifiedMachineID
			case "alias-point":
				raw, _ := base64.StdEncoding.DecodeString(p[1].AttestationResult.PublicKey)
				key := base64.StdEncoding.EncodeToString(raw[1:])
				p[0].AttestationResult.PublicKey = key
				p[0].appAttestAuthorization.VerifiedControlPublicKey = key
			}
			unlock()
			r.mu.Unlock()
			if _, _, err := r.ReserveVerifiedPair(p, request); err == nil {
				t.Fatal("substituted authority/device admitted")
			}
			r.mu.RLock()
			held := len(r.verifiedPairs.states)
			r.mu.RUnlock()
			if held != 0 {
				t.Fatal("refusal leaked partial hold")
			}
		})
	}
}
func TestVerifiedPairAppAttestRevalidatesAtPreparedAndCommit(t *testing.T) {
	for _, at := range []string{"prepared", "commit", "request"} {
		t.Run(at, func(t *testing.T) {
			r, p, request, _ := appAttestPairFixture(t)
			h, m := pairTestReserve(t, r, p, request)
			if at != "prepared" {
				pairTestPrepare(t, r, h, p, m)
			}
			if at == "request" {
				if _, err := r.CommitVerifiedPairOwners(h); err != nil {
					t.Fatal(err)
				}
			}
			p[0].mu.Lock()
			p[0].appAttestAuthorization.ProofSessionID = "replacement"
			p[0].mu.Unlock()
			var err error
			switch at {
			case "prepared":
				err = r.AcknowledgeVerifiedPairPrepared(h, p[0], m.TranscriptSHA256)
			case "commit":
				_, err = r.CommitVerifiedPairOwners(h)
			case "request":
				_, err = r.ValidateVerifiedPair(h)
			}
			if err == nil {
				t.Fatal("changed proof reached next phase")
			}
			pairTestDone(t, h)
			want := VerifiedPairReleased
			if at == "request" {
				want = VerifiedPairQuarantined
			}
			pairTestRequirePhase(t, r, h, want)
		})
	}
}

func TestVerifiedPairAppAttestLiveAliasPreventsInitialReservation(t *testing.T) {
	for _, kind := range []string{"machine", "point"} {
		t.Run(kind, func(t *testing.T) {
			r, p, request, leases := appAttestPairFixture(t)
			alias := pairTestMember(t, r, "other-live-connection", "other-serial")
			machine := "other-machine"
			if kind == "machine" {
				machine = leases[0].MachineID
			}
			pairTestAppAttest(t, r, alias, machine)
			if kind == "point" {
				raw, _ := base64.StdEncoding.DecodeString(leases[0].VerifiedControlPublicKey)
				alias.mu.Lock()
				alias.AttestationResult.PublicKey = base64.StdEncoding.EncodeToString(raw[1:])
				alias.appAttestAuthorization.VerifiedControlPublicKey = alias.AttestationResult.PublicKey
				alias.mu.Unlock()
			}
			if _, _, err := r.ReserveVerifiedPair(p, request); err == nil {
				t.Fatal("another live physical alias bypassed preparation")
			}
		})
	}
}
