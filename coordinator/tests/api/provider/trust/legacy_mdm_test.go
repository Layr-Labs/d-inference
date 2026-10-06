package trust_test

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	attestservice "github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/deviceverification"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/verification"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func freezeLegacyMDMCohort(t *testing.T, s *trustFixture) {
	t.Helper()
	ctx := context.Background()
	old := time.Now().Add(-time.Hour)
	if err := s.store.CreateUser(&store.User{AccountID: "old-account", PrivyUserID: "did:privy:old-account", CreatedAt: old}); err != nil {
		t.Fatal(err)
	}
	inventory, ok := store.As[store.MachineInventoryStore](s.store)
	if !ok {
		t.Fatal("fixture store does not support machine inventory")
	}
	if _, err := inventory.ObserveMachine(ctx, store.MachineObservation{SessionID: "old-session", AccountID: "old-account", SEKey: "se-pub-key-bytes", VerifiedSerial: "SERIAL-1", At: old}); err != nil {
		t.Fatal(err)
	}
	evidence, err := json.Marshal(attestation.VerificationResult{
		Valid: true, SecureEnclaveAvailable: true, SIPEnabled: true, SecureBootEnabled: true,
		PublicKey: "se-pub-key-bytes", SerialNumber: "SERIAL-1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := s.store.UpsertProvider(ctx, store.ProviderRecord{
		ID: "old-session", AccountID: "old-account", SEPublicKey: "se-pub-key-bytes", SerialNumber: "SERIAL-1",
		RegisteredAt: old, TrustLevel: string(registry.TrustHardware), Attested: true, AttestationResult: evidence,
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.LegacyMDM.Initialize(ctx, attestservice.Config{ServingEnabled: true, Environment: "production", RolloutPercent: 100}); err != nil {
		t.Fatal(err)
	}
	if !s.LegacyMDM.IdentityAllowed("old-account", "se-pub-key-bytes", "SERIAL-1") {
		t.Fatal("historically verified machine missing from frozen cohort")
	}
}

func TestLegacyMDMIneligibleCannotScheduleOrReuseTrust(t *testing.T) {
	for _, identity := range []string{"new account", "new key", "changed serial", "invalid attestation"} {
		t.Run(identity, func(t *testing.T) {
			fake := &fakeMDMServer{}
			s, p := mdmReliabilityServer(t, fake)
			freezeLegacyMDMCohort(t, s)
			p.Mu().Lock()
			p.AccountID = "old-account"
			p.AttestationResult.BinaryHash = trHashA
			switch identity {
			case "new account":
				p.AccountID = "new-account"
			case "new key":
				p.AttestationResult.PublicKey = "new-key"
			case "changed serial":
				p.AttestationResult.SerialNumber = "new-serial"
			case "invalid attestation":
				p.AttestationResult.Valid = false
			}
			p.Mu().Unlock()
			ar := attestResultOf(p)
			if generation := s.verificationBackend.Scheduler.Submit(context.Background(), p.ID, p, store.VerificationPriorityFirstOrExpired); generation != 0 {
				t.Fatalf("ineligible scheduler submission generation=%d", generation)
			}
			if job, err := s.store.GetVerificationJob(context.Background(), ar.PublicKey, store.VerificationTaskSecurityInfo); err != nil || job != nil {
				t.Fatalf("ineligible submission created durable job: %+v, %v", job, err)
			}
			if p.GetMDMFailureReason() != "app-attest-required" || fake.pushCount() != 0 {
				t.Fatal("ineligible submission did not stop before MDM work")
			}
			s.SeedTrustReuseCache(context.Background())
			for _, hash := range []string{trHashA, ""} {
				if s.RecordTrustReuse(p, ar.PublicKey, ar.SerialNumber, hash, true, true, "UDID-1") ||
					s.RecordLateTrustReuse(p, ar.PublicKey, ar.SerialNumber, hash, true, true, "UDID-1") {
					t.Fatal("ineligible machine recorded or granted live trust")
				}
			}
			if rows, err := s.store.ListProviderTrustReuse(context.Background()); err != nil || len(rows) != 0 {
				t.Fatalf("ineligible machine persisted trust: %+v, %v", rows, err)
			}
			record := hardwareReuseRecord(ar.PublicKey, ar.SerialNumber, trHashA, s.trustReuseCache.Now())
			if _, err := s.store.UpsertProviderTrustReuse(context.Background(), record, 0); err != nil {
				t.Fatal(err)
			}
			s.trustReuseCache.RecordTrust(s.trustReuseCache.PublicationGeneration(), record)
			if s.TryTrustReuseFastSkip(p.ID, p, goodFastSkipResp(), true) || p.GetTrustLevel() != registry.TrustSelfSigned {
				t.Fatal("seeded cache bypassed frozen machine eligibility")
			}
			s.verificationBackend.Scheduler.EnqueueMDA(verification.Binding{Provider: p, Attestation: ar}, "UDID-1")
			if job, err := s.store.GetVerificationJob(context.Background(), ar.PublicKey, store.VerificationTaskMDA); err != nil || job != nil {
				t.Fatalf("ineligible MDA follow-up created durable job: %+v, %v", job, err)
			}
		})
	}
}

func TestLegacyMDMLiveVerificationGrandfatheredOnly(t *testing.T) {
	for _, old := range []bool{true, false} {
		t.Run(fmt.Sprintf("grandfathered=%t", old), func(t *testing.T) {
			fake := &fakeMDMServer{device: &mdm.DeviceInfo{SerialNumber: "SERIAL-1", UDID: "UDID-1", EnrollmentStatus: true}, commandUUID: "legacy-live", failMDARawCommand: true}
			s, p := mdmReliabilityServer(t, fake)
			freezeLegacyMDMCohort(t, s)
			p.Mu().Lock()
			p.AccountID = "old-account"
			if !old {
				p.AttestationResult.PublicKey = "new-key"
			}
			p.Mu().Unlock()
			s.SeedTrustReuseCache(context.Background())
			if old {
				deliverWebhookWhenPushed(s, fake, "UDID-1", "legacy-live", true, true)
			}
			outcome := s.VerifyProviderViaMDM(context.Background(), p.ID, p, attestResultOf(p))
			if old {
				if outcome != deviceverification.Granted || p.GetTrustLevel() != registry.TrustHardware || fake.pushCount() == 0 {
					t.Fatalf("grandfathered live verification failed: outcome=%v trust=%s", outcome, p.GetTrustLevel())
				}
			} else if outcome != deviceverification.Terminal || p.GetTrustLevel() != registry.TrustSelfSigned || fake.pushCount() != 0 || p.GetMDMFailureReason() != "app-attest-required" {
				t.Fatal("new machine used live MDM verification")
			}
		})
	}
}

func TestLegacyMDMLateSecurityInfoCannotGrantIneligibleMachine(t *testing.T) {
	s, p := mdmReliabilityServer(t, &fakeMDMServer{})
	p.Mu().Lock()
	p.AccountID = "new-account"
	p.AttestationResult.BinaryHash = trHashA
	p.Mu().Unlock()
	s.SeedTrustReuseCache(context.Background())
	// Bind the command before freezing to exercise the late grant gate itself.
	bindLateSecurityInfoForTest(t, s, p, "UDID-1")
	freezeLegacyMDMCohort(t, s)
	s.trustReuseCache.RecordTrust(s.trustReuseCache.PublicationGeneration(), hardwareReuseRecord("se-pub-key-bytes", "SERIAL-1", trHashA, s.trustReuseCache.Now()))
	p.SetMDMFailureReason("securityinfo-timeout")
	s.ApplyLateSecurityInfo("UDID-1", lateSecurityInfoCommandUUID, &mdm.SecurityInfoResponse{SystemIntegrityProtectionEnabled: true, SecureBootLevel: "full"})
	if p.GetTrustLevel() != registry.TrustSelfSigned || p.GetMDMFailureReason() != "securityinfo-timeout" {
		t.Fatal("late SecurityInfo granted or cleared failure for an ineligible identity")
	}
	if rows, err := s.store.ListProviderTrustReuse(context.Background()); err != nil || len(rows) != 0 {
		t.Fatalf("late ineligible callback persisted trust: %+v, %v", rows, err)
	}
}
