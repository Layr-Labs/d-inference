package api

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestProcessPostureShadowFreshRequestUsesBaselineNonce(t *testing.T) {
	fake := &fakeMDMServer{}
	s, p := mdmReliabilityServer(t, fake, ServerConfig{ProcessPostureMode: ProcessPostureShadow})
	p.Mu().Lock()
	p.TrustLevel = registry.TrustHardware
	p.Mu().Unlock()
	ar := attestResultOf(p)
	want := sha256.Sum256([]byte(ar.PublicKey))
	chain, root := mintMDALeafChain(t, ar.SerialNumber, want[:])
	defer attestation.OverrideRootCAForTest(root)()
	done := make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { defer close(done); s.verifyAppleDeviceAttestation(ctx, p.ID, p, ar, "UDID-1") }()
	command := waitForMDACommand(t, fake)
	fake.mu.Lock()
	body := fake.mdaCommandBody
	fake.mu.Unlock()
	if !strings.Contains(body, "<data>"+base64.StdEncoding.EncodeToString(want[:])+"</data>") {
		t.Fatalf("baseline nonce missing from MDA request: %s", body)
	}
	s.mdmClient.HandleWebhook(deviceAttestationWebhook("UDID-1", command, chain...))
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("fresh baseline MDA did not finish")
	}
	if !mdaVerified(p) || p.GetTrustLevel() != registry.TrustHardware {
		t.Fatal("strict shadow verdict changed baseline MDA outcome")
	}
}

func TestProcessPostureShadowLateSecurityInfoUsesBaselineCacheWithoutNewJob(t *testing.T) {
	fake := &fakeMDMServer{}
	s, p := mdmReliabilityServer(t, fake, ServerConfig{ProcessPostureMode: ProcessPostureShadow})
	s.SeedTrustReuseCache(context.Background())
	withoutLiveDispatcher(s.mdmScheduler)
	_, _, _, se := providerKeyMaterial(t)
	p.Mu().Lock()
	p.AttestationResult.PublicKey = se
	p.Mu().Unlock()
	ar := attestResultOf(p)
	nonce := sha256.Sum256([]byte(ar.PublicKey))
	chain, root := mintMDALeafChain(t, ar.SerialNumber, nonce[:])
	defer attestation.OverrideRootCAForTest(root)()
	raw, _ := json.Marshal(chain)
	p.StageMDAChainFromJSON(raw)
	bindLateSecurityInfoForTest(t, s, p, "UDID-1")
	s.ApplyLateSecurityInfo("UDID-1", lateSecurityInfoCommandUUID, &mdm.SecurityInfoResponse{SystemIntegrityProtectionEnabled: true, SecureBootLevel: "full"})
	if p.GetTrustLevel() != registry.TrustHardware || !mdaVerified(p) || p.GetMDMFailureReason() != "" {
		t.Fatalf("baseline late grant changed: %+v", snapshotShadowTrust(p))
	}
	s.mdmScheduler.mu.Lock()
	mdaJob := s.mdmScheduler.jobs[verificationSchedulerKey(ar.PublicKey, store.VerificationTaskMDA)]
	s.mdmScheduler.mu.Unlock()
	if mdaJob != nil || fake.pushCount() != 0 {
		t.Fatal("strict observer caused a fresh MDA job")
	}
	if !strings.Contains(s.metrics.Snapshot().RenderProm(), `reason="legacy_nonce"`) {
		t.Fatal("cached legacy certificate was not observed")
	}
}

func TestProcessPostureShadowLateMDAKeepsExactOwnershipAndBaselineProof(t *testing.T) {
	s, p := mdmReliabilityServer(t, &fakeMDMServer{}, ServerConfig{ProcessPostureMode: ProcessPostureShadow})
	sch := s.mdmScheduler
	withoutLiveDispatcher(sch)
	p.Mu().Lock()
	p.TrustLevel = registry.TrustHardware
	p.Mu().Unlock()
	ar := attestResultOf(p)
	generation := sch.generation.Add(1)
	binding := mdmLiveBinding{providerID: p.ID, provider: p, attestation: ar, generation: generation, ctx: context.Background(), challengeSettled: true, allowMDA: true}
	sch.mu.Lock()
	sch.bindings[ar.PublicKey] = &binding
	sch.mu.Unlock()
	sch.enqueueMDA(binding, "UDID-1")
	key := verificationSchedulerKey(ar.PublicKey, store.VerificationTaskMDA)
	sch.mu.Lock()
	sch.jobs[key].callbackGen = generation
	sch.jobs[key].callbackUUID = "owned"
	sch.byUDID["UDID-1"] = key
	sch.mu.Unlock()
	nonce := sha256.Sum256([]byte(ar.PublicKey))
	chain, root := mintMDALeafChain(t, ar.SerialNumber, nonce[:])
	defer attestation.OverrideRootCAForTest(root)()
	s.ApplyLateMDA("UDID-1", "stale-command", chain)
	if mdaVerified(p) {
		t.Fatal("unowned callback attached proof")
	}
	s.ApplyLateMDA("UDID-1", "owned", chain)
	if !mdaVerified(p) || p.GetTrustLevel() != registry.TrustHardware {
		t.Fatal("shadow changed baseline late MDA attachment")
	}
	record, err := s.store.GetVerificationJob(context.Background(), ar.PublicKey, store.VerificationTaskMDA)
	if err != nil || record == nil || record.State != store.VerificationStateCompleted {
		t.Fatalf("late baseline job incomplete: %+v %v", record, err)
	}
	if _, _, ready := p.ProcessPostureReady(); ready {
		t.Fatal("baseline callback installed strict posture")
	}
}

func TestProcessPostureShadowLateBadSecurityInfoStillRevokes(t *testing.T) {
	s, p := mdmReliabilityServer(t, &fakeMDMServer{}, ServerConfig{ProcessPostureMode: ProcessPostureShadow})
	s.SeedTrustReuseCache(context.Background())
	withoutLiveDispatcher(s.mdmScheduler)
	bindLateSecurityInfoForTest(t, s, p, "UDID-1")
	s.ApplyLateSecurityInfo("UDID-1", lateSecurityInfoCommandUUID, &mdm.SecurityInfoResponse{SystemIntegrityProtectionEnabled: false, SecureBootLevel: "full"})
	if p.GetStatus() != registry.StatusUntrusted || p.GetMDMFailureReason() != "posture-mismatch" {
		t.Fatal("baseline negative OS evidence lost its revocation behavior")
	}
}

func TestProcessPostureLateMDARechecksBindingAfterValidation(t *testing.T) {
	for _, mode := range []ProcessPostureMode{ProcessPostureShadow, ProcessPostureEnforce} {
		t.Run(string(mode), func(t *testing.T) {
			s, p := mdmReliabilityServer(t, &fakeMDMServer{}, ServerConfig{ProcessPostureMode: mode})
			sch := s.mdmScheduler
			withoutLiveDispatcher(sch)
			_, _, _, se := providerKeyMaterial(t)
			p.Mu().Lock()
			p.AttestationResult.PublicKey = se
			p.AttestationResult.BinaryHash = trHashA
			p.CodeAttested, p.FreshCodeAttested, p.ChallengeVerifiedSIP = true, true, true
			if mode == ProcessPostureShadow {
				p.TrustLevel = registry.TrustHardware
			}
			p.Mu().Unlock()
			if mode == ProcessPostureEnforce {
				p.RequireProcessPosture()
			}
			ar := attestResultOf(p)
			generation := sch.generation.Add(1)
			binding := mdmLiveBinding{providerID: p.ID, provider: p, attestation: ar, generation: generation, ctx: context.Background(), challengeSettled: true, allowMDA: true}
			sch.mu.Lock()
			sch.bindings[se] = &binding
			sch.mu.Unlock()
			sch.enqueueMDA(binding, "UDID-1")
			key := verificationSchedulerKey(se, store.VerificationTaskMDA)
			sch.mu.Lock()
			sch.jobs[key].callbackGen = generation
			sch.jobs[key].callbackUUID = "old"
			sch.byUDID["UDID-1"] = key
			sch.mu.Unlock()
			var nonce []byte
			if mode == ProcessPostureShadow {
				legacy := sha256.Sum256([]byte(se))
				nonce = legacy[:]
			} else {
				nonce, _ = attestation.ProcessPostureNonce(se, p.PublicKey)
			}
			chain, root := mintMDALeafChain(t, ar.SerialNumber, nonce)
			defer attestation.OverrideRootCAForTest(root)()
			before := snapshotShadowTrust(p)
			calls := 0
			sch.deps.verifyMDA = func(der [][]byte) (*attestation.MDAResult, error) {
				proof, err := attestation.VerifyMDADeviceAttestation(der)
				calls++
				sch.mu.Lock()
				replacement := binding
				replacement.generation = sch.generation.Add(1)
				sch.bindings[se] = &replacement
				sch.jobs[key].bindingGen = replacement.generation
				sch.jobs[key].callbackGen = replacement.generation
				sch.jobs[key].callbackUUID = "replacement"
				sch.mu.Unlock()
				return proof, err
			}
			s.ApplyLateMDA("UDID-1", "old", chain)
			if calls != 1 {
				t.Fatalf("validation count=%d", calls)
			}
			if after := snapshotShadowTrust(p); !reflect.DeepEqual(before, after) {
				t.Fatal("callback mutated provider after ownership changed during validation")
			}
			rec, err := s.store.GetVerificationJob(context.Background(), se, store.VerificationTaskMDA)
			if err != nil || rec == nil || rec.State == store.VerificationStateCompleted {
				t.Fatalf("stale callback completed replacement job: %+v %v", rec, err)
			}
		})
	}
}
