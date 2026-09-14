package api

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Proofs and push budgets bind at startup; connection coverage intentionally
// discovers the current store. Exercise those bindings through a real encrypted
// nonce/signature round trip and the ordinary coverage sweep.
func TestCodeIdentityKeepsStartupProofAndLiveCoverageStores(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	initial := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(quietLogger()), initial, ServerConfig{}, quietLogger())
	defer srv.Close()
	fastBudgets(srv)
	srv.SeedCodeAttestCache(ctx)
	replacement := store.NewMemory(store.Config{})
	srv.store = replacement

	pub, priv, signer, se := providerKeyMaterial(t)
	p := srv.registry.Register("code-store-binding", nil, &protocol.RegisterMessage{
		Type: protocol.TypeRegister, Backend: "mlx-swift", PublicKey: pub,
		Models: []protocol.ModelInfo{{ID: "m", ModelType: "chat", Quantization: "4bit"}},
	})
	identity := newCodeAttestProvider(pub, se)
	p.Mu().Lock()
	p.AttestationResult = identity.AttestationResult
	p.AttestationResult.BinaryHash = trHashA
	p.Version, p.APNsDeviceToken = "0.9.0", identity.APNsDeviceToken
	p.Status, p.TrustLevel = registry.StatusOnline, registry.TrustHardware
	p.Mu().Unlock()
	p.SignalApplicationProofSettled()
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, target, nonce string) error {
		return completeRoundTrip(t, srv, p, p.ID, priv, signer, target, nonce)
	}})
	srv.codeAttestLoop(ctx, p.ID, p)
	if !p.GetCodeAttested() || !p.GetFreshCodeAttested() {
		t.Fatal("the encrypted nonce/signature round trip did not grant the live process proof")
	}
	var proof store.CodeAttestation
	if !waitForCond(2*time.Second, func() bool {
		rows, err := initial.ListCodeAttestations(ctx)
		if err != nil || len(rows) != 1 {
			return false
		}
		proof = rows[0]
		return proof.SEPubKey == se && proof.NodePublicKey == pub && proof.BinaryHash == trHashA
	}) {
		t.Fatal("the startup store did not receive the verified proof")
	}
	if rows, err := replacement.ListCodeAttestations(ctx); err != nil || len(rows) != 0 {
		t.Fatalf("the replacement store received a startup-bound proof: rows=%+v err=%v", rows, err)
	}
	if budgets, err := initial.ListCodeAttestPushBudgets(ctx); err != nil || len(budgets) == 0 {
		t.Fatalf("the startup store did not reserve the push budget: rows=%+v err=%v", budgets, err)
	}
	if budgets, err := replacement.ListCodeAttestPushBudgets(ctx); err != nil || len(budgets) != 0 {
		t.Fatalf("the replacement store received a startup-bound push budget: rows=%+v err=%v", budgets, err)
	}
	if proof.ContinuousCoverageUntil != nil {
		t.Fatal("a new APNs proof manufactured a continuity watermark")
	}
	if err := replacement.UpsertCodeAttestation(ctx, proof); err != nil {
		t.Fatal(err)
	}
	srv.sweepCodeAttestCoverage()
	rows, err := replacement.ListCodeAttestations(ctx)
	if err != nil || len(rows) != 1 || rows[0].ContinuousCoverageUntil == nil || rows[0].ContinuousCoverageUntil.Before(proof.AttestedAt) {
		t.Fatalf("the current store did not receive verified connection coverage: rows=%+v err=%v", rows, err)
	}
	rows, err = initial.ListCodeAttestations(ctx)
	if err != nil || len(rows) != 1 || rows[0].ContinuousCoverageUntil != nil {
		t.Fatalf("coverage was redirected to the startup proof store: rows=%+v err=%v", rows, err)
	}
}

func TestCodeIdentityAbsentReleasePolicyCannotResume(t *testing.T) {
	srv := NewServer(registry.New(quietLogger()), store.NewMemory(store.Config{}), ServerConfig{}, quietLogger())
	defer srv.Close()
	fastBudgets(srv)
	pub, _, _, se := providerKeyMaterial(t)
	p := crossVersionProvider(pub, se, "0.9.0")
	seedFreshProcessAttestation(t, srv, se, "0.8.0", p.APNsDeviceToken, pub, trHashB)
	armCrossVersionApplicationEvidence(t, srv, p, se)
	resetReleasePolicyForTest(srv)
	if srv.tryCrossVersionReuse(context.Background(), p.ID, p) || p.GetCodeAttested() || p.GetFreshCodeAttested() {
		t.Fatal("absent release policy authorized a resume or granted code trust")
	}
}
