package api

// Regression tests for the active-model-hash RACE that false-untrusted busy
// dual-model providers in prod.
//
// The challenge response used to be validated by comparing
// resp.ActiveModelHash (the hash of whatever model the PROVIDER considered
// current when it built the response) against the catalog hash of
// provider.CurrentModel (the model the COORDINATOR believed current, from the
// last heartbeat — up to a heartbeat interval stale). On a provider serving
// two models with interleaved traffic, the current model flips between
// heartbeats, so a perfectly correct hash of model B was misread as a
// tampered hash of model A → false "model swap" hard-untrust.
//
// The fix validates the model-keyed resp.ModelHashes map against the catalog
// — exact and race-free. The bare active_model_hash is additionally checked
// by membership (it must match SOME advertised model's catalog hash), which
// runs regardless of the map — so a map of only empty/unknown entries cannot
// suppress it — but only when every advertised model has an enforced catalog
// hash; otherwise the bare hash could legitimately belong to an unenforced
// model and proves nothing.

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

const (
	gemmaHash  = "a4722b6020adb1894c700b45ddcd58bc0e0f033abe7139f86cbbbfe60cba4eb6"
	gptOSSHash = "61bfc04e4016a7fa487eb10e29f79360047e302487229f298da3681984aec512"
)

// challengeExchange registers a dual-model provider, makes the coordinator
// believe "model-gemma" is current (via heartbeat), then answers the first
// challenge with the given hash payload. Returns the provider's final status.
func challengeExchange(
	t *testing.T,
	modelHashes map[string]string,
	activeModelHash string,
) registry.ProviderStatus {
	t.Helper()
	return challengeExchangeWithCatalog(t, []registry.CatalogEntry{
		{ID: "model-gemma", WeightHash: gemmaHash},
		{ID: "model-gptoss", WeightHash: gptOSSHash},
	}, modelHashes, activeModelHash)
}

// challengeExchangeWithCatalog is challengeExchange with a caller-supplied
// model catalog (to exercise unenforced catalog entries).
func challengeExchangeWithCatalog(
	t *testing.T,
	catalog []registry.CatalogEntry,
	modelHashes map[string]string,
	activeModelHash string,
) registry.ProviderStatus {
	t.Helper()
	return challengeExchangeAdvertising(t, catalog, []protocol.ModelInfo{
		{ID: "model-gemma", SizeBytes: 1000, ModelType: "chat", Quantization: "8bit", WeightHash: gemmaHash},
		{ID: "model-gptoss", SizeBytes: 1000, ModelType: "chat", Quantization: "4bit", WeightHash: gptOSSHash},
	}, modelHashes, activeModelHash)
}

// challengeExchangeAdvertising additionally takes the ADVERTISED model set, so
// tests can shape the post-hot-swap state where a still-resident build reports
// a hash without being advertised any more.
func challengeExchangeAdvertising(
	t *testing.T,
	catalog []registry.CatalogEntry,
	advertised []protocol.ModelInfo,
	modelHashes map[string]string,
	activeModelHash string,
) registry.ProviderStatus {
	t.Helper()
	return challengeExchangeFull(t, catalog, advertised, nil, modelHashes, activeModelHash)
}

// challengeExchangeFull additionally takes alias lineage, so tests can mark a
// build as a retired/previous alias member (the legitimate hot-swap residency
// case the active-hash alibi is scoped to).
func challengeExchangeFull(
	t *testing.T,
	catalog []registry.CatalogEntry,
	advertised []protocol.ModelInfo,
	aliases map[string]registry.AliasTarget,
	modelHashes map[string]string,
	activeModelHash string,
) registry.ProviderStatus {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	reg.SetModelCatalog(catalog)
	if aliases != nil {
		reg.SetModelAliases(aliases)
	}
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 200 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	pubKey := testPublicKeyB64()
	regMsg := protocol.RegisterMessage{
		Type:      protocol.TypeRegister,
		Hardware:  protocol.Hardware{ChipName: "Apple M2 Ultra", MemoryGB: 128},
		Models:    advertised,
		Backend:   "mlx-swift",
		PublicKey: pubKey,
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}

	// Heartbeat: the coordinator's last word is "model-gemma is current".
	active := "model-gemma"
	hb := protocol.HeartbeatMessage{
		Type:        protocol.TypeHeartbeat,
		Status:      "serving",
		ActiveModel: &active,
	}
	hbData, _ := json.Marshal(hb)
	if err := conn.Write(ctx, websocket.MessageText, hbData); err != nil {
		t.Fatalf("write heartbeat: %v", err)
	}

	// Answer the first challenge with the supplied hash payload.
	answered := false
	for range 30 {
		readCtx, readCancel := context.WithTimeout(ctx, 500*time.Millisecond)
		_, data, err := conn.Read(readCtx)
		readCancel()
		if err != nil {
			continue
		}
		var envelope struct {
			Type string `json:"type"`
		}
		_ = json.Unmarshal(data, &envelope)
		if envelope.Type != protocol.TypeAttestationChallenge {
			continue
		}
		var challenge protocol.AttestationChallengeMessage
		_ = json.Unmarshal(data, &challenge)
		rdmaDisabled := true
		sipEnabled := true
		secureBootEnabled := true
		resp := protocol.AttestationResponseMessage{
			Type:              protocol.TypeAttestationResponse,
			Nonce:             challenge.Nonce,
			Signature:         testChallengeSignature(challenge.Nonce, challenge.Timestamp, pubKey),
			PublicKey:         pubKey,
			RDMADisabled:      &rdmaDisabled,
			SIPEnabled:        &sipEnabled,
			SecureBootEnabled: &secureBootEnabled,
			ActiveModelHash:   activeModelHash,
			ModelHashes:       modelHashes,
		}
		respData, _ := json.Marshal(resp)
		if err := conn.Write(ctx, websocket.MessageText, respData); err != nil {
			t.Fatalf("write challenge response: %v", err)
		}
		answered = true
		break
	}
	if !answered {
		t.Fatal("no attestation challenge received")
	}

	// Give the coordinator time to process, then read the provider's status.
	time.Sleep(300 * time.Millisecond)
	ids := reg.ProviderIDs()
	if len(ids) != 1 {
		t.Fatalf("expected 1 provider, got %d", len(ids))
	}
	p := reg.GetProvider(ids[0])
	p.Mu().Lock()
	defer p.Mu().Unlock()
	return p.Status
}

// TestChallengeCorrectHashesOfOtherModelDoNotUntrust reproduces the prod race:
// the coordinator believes model-gemma is current (heartbeat), but the
// provider's active model flipped to model-gptoss before it answered — so
// active_model_hash is gptoss's (correct) hash while the coordinator expects
// gemma's. With correct per-model hashes in model_hashes, the provider must
// NOT be untrusted. Fails on the old guess-based check.
func TestChallengeCorrectHashesOfOtherModelDoNotUntrust(t *testing.T) {
	status := challengeExchange(t,
		map[string]string{"model-gemma": gemmaHash, "model-gptoss": gptOSSHash},
		gptOSSHash, // hash of the model the provider ACTUALLY has active
	)
	if status == registry.StatusUntrusted {
		t.Fatal("provider with correct per-model hashes was untrusted (active-model guess race)")
	}
}

// TestChallengeWrongModelHashUntrusts: a genuinely wrong hash for an advertised
// model must still hard-untrust (the security check stays effective).
func TestChallengeWrongModelHashUntrusts(t *testing.T) {
	status := challengeExchange(t,
		map[string]string{"model-gemma": "deadbeef" + gemmaHash[8:], "model-gptoss": gptOSSHash},
		gptOSSHash,
	)
	if status != registry.StatusUntrusted {
		t.Fatalf("provider with tampered model hash was not untrusted (status=%s)", status)
	}
}

// TestChallengeLegacyActiveHashMatchingAnyModelAccepted: legacy responses with
// no model_hashes map are accepted when active_model_hash matches ANY
// advertised model's catalog hash (membership, not the racy current-model guess).
func TestChallengeLegacyActiveHashMatchingAnyModelAccepted(t *testing.T) {
	status := challengeExchange(t, nil, gptOSSHash)
	if status == registry.StatusUntrusted {
		t.Fatal("legacy response with a valid advertised-model hash was untrusted")
	}
}

// TestChallengeLegacyActiveHashMatchingNothingUntrusts: a legacy response whose
// active hash matches no advertised model is still rejected.
func TestChallengeLegacyActiveHashMatchingNothingUntrusts(t *testing.T) {
	status := challengeExchange(t, nil, "deadbeef"+gemmaHash[8:])
	if status != registry.StatusUntrusted {
		t.Fatalf("legacy response with unknown hash was not untrusted (status=%s)", status)
	}
}

// TestChallengeUselessMapDoesNotSuppressActiveHashCheck: a model_hashes map
// holding only empty or unknown entries must not act as a bypass — the bare
// active_model_hash membership check still runs and rejects a bogus hash.
// (Review finding: with the fallback gated on len(resp.ModelHashes) == 0, a
// malicious provider could send {"model-gemma": ""} plus a bad active hash
// and skip both checks.)
func TestChallengeUselessMapDoesNotSuppressActiveHashCheck(t *testing.T) {
	status := challengeExchange(t,
		map[string]string{"model-gemma": "", "not-in-catalog": "ffff" + gemmaHash[4:]},
		"deadbeef"+gemmaHash[8:],
	)
	if status != registry.StatusUntrusted {
		t.Fatalf("useless model_hashes map suppressed the active-hash check (status=%s)", status)
	}
}

// TestChallengeBareHashSkippedWhenAnyModelUnenforced: when an advertised model
// has no enforced catalog hash, a bare active_model_hash matching nothing is
// inconclusive — it could legitimately be that model's hash — so the provider
// must NOT be untrusted.
func TestChallengeBareHashSkippedWhenAnyModelUnenforced(t *testing.T) {
	status := challengeExchangeWithCatalog(t,
		[]registry.CatalogEntry{
			{ID: "model-gemma", WeightHash: gemmaHash},
			{ID: "model-gptoss", WeightHash: ""}, // unenforced
		},
		nil,
		"deadbeef"+gemmaHash[8:], // plausibly model-gptoss's real hash
	)
	if status == registry.StatusUntrusted {
		t.Fatal("bare hash untrusted despite an unenforced advertised model (inconclusive check)")
	}
}

// TestChallengeRetiredResidentBuildHashDoesNotUntrust: the alias hot-swap
// shape. After a hard-swap the provider advertises ONLY the new build, but the
// retired build stays GPU-resident (idle monitor drains it later) and remains
// the provider's "active" model until the first inference on the new build.
// Its hash arrives in model_hashes and matches its own catalog entry — a
// known-good registered build, not a swap. The provider must NOT be untrusted,
// or every fleet migration mass-deroutes itself at the next challenge tick.
func TestChallengeRetiredResidentBuildHashDoesNotUntrust(t *testing.T) {
	status := challengeExchangeFull(t,
		[]registry.CatalogEntry{
			{ID: "model-gemma", WeightHash: gemmaHash},   // retired build, still in catalog
			{ID: "model-gptoss", WeightHash: gptOSSHash}, // the new (desired) build
		},
		// Advertised set post-swap: ONLY the new build.
		[]protocol.ModelInfo{
			{ID: "model-gptoss", SizeBytes: 1000, ModelType: "chat", Quantization: "4bit", WeightHash: gptOSSHash},
		},
		// Alias lineage: model-gemma is the PREVIOUS member (the hot-swap source).
		map[string]registry.AliasTarget{
			"gemma-4-26b": {Desired: "model-gptoss", Previous: "model-gemma"},
		},
		// Reported hashes: both loaded slots (retired build still resident).
		map[string]string{"model-gemma": gemmaHash, "model-gptoss": gptOSSHash},
		gemmaHash, // active model = the retired-but-resident build
	)
	if status == registry.StatusUntrusted {
		t.Fatal("post-swap provider untrusted for its retired-but-resident alias build's valid hash")
	}
}

// TestChallengeAlibiRejectsNonAliasModel: the alibi must NOT let a provider
// claim an arbitrary catalog model (not part of any alias lineage) as active to
// dodge the membership check. model-gemma here is a real catalog build but is
// NOT a previous/retired alias member, so reporting it as active while
// advertising only model-gptoss must still untrust.
func TestChallengeAlibiRejectsNonAliasModel(t *testing.T) {
	status := challengeExchangeFull(t,
		[]registry.CatalogEntry{
			{ID: "model-gemma", WeightHash: gemmaHash},
			{ID: "model-gptoss", WeightHash: gptOSSHash},
		},
		[]protocol.ModelInfo{
			{ID: "model-gptoss", SizeBytes: 1000, ModelType: "chat", Quantization: "4bit", WeightHash: gptOSSHash},
		},
		nil, // no alias lineage — model-gemma is just another catalog model
		map[string]string{"model-gemma": gemmaHash, "model-gptoss": gptOSSHash},
		gemmaHash,
	)
	if status != registry.StatusUntrusted {
		t.Fatalf("alibi accepted a non-alias-member model as active (status=%s)", status)
	}
}

// TestChallengeRetiredAlibiDoesNotWeakenTamperCheck: the retired-build alibi
// must not soften the membership check — an active hash matching neither the
// advertised set nor any catalog-validated reported hash still untrusts, even
// when valid reported hashes are present.
func TestChallengeRetiredAlibiDoesNotWeakenTamperCheck(t *testing.T) {
	status := challengeExchangeAdvertising(t,
		[]registry.CatalogEntry{
			{ID: "model-gemma", WeightHash: gemmaHash},
			{ID: "model-gptoss", WeightHash: gptOSSHash},
		},
		[]protocol.ModelInfo{
			{ID: "model-gptoss", SizeBytes: 1000, ModelType: "chat", Quantization: "4bit", WeightHash: gptOSSHash},
		},
		map[string]string{"model-gemma": gemmaHash, "model-gptoss": gptOSSHash},
		"deadbeef"+gemmaHash[8:], // tampered active hash
	)
	if status != registry.StatusUntrusted {
		t.Fatalf("tampered active hash slipped past the retired-build alibi (status=%s)", status)
	}
}
