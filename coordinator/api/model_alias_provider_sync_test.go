package api

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
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

// A provider that connects over the real WebSocket path and advertises a build
// under an existing alias is pushed desired_models right after register.
func TestProviderReceivesDesiredModelsAfterRegister(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = time.Hour // don't race the desired_models read with a challenge
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	seedActiveModel(t, st, aliasFP8, "fp8")
	seedActiveModel(t, st, aliasQAT, "qat")
	// Alias exists BEFORE the provider connects: desired = qat, previous = fp8.
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		DesiredBuild: aliasQAT, PreviousBuild: aliasFP8,
	}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Provider advertises the previous build (fp8) and runs a feature-version
	// Swift binary, so it qualifies for desired_models.
	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{MachineModel: "Mac15,8", ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: aliasFP8, ModelType: "chat", Quantization: "4bit"}},
		Backend:                 registry.BackendMLXSwift,
		Version:                 minProviderVersionForDesiredModels,
		PublicKey:               "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}

	// Read until we see desired_models (other messages like trust_status may
	// arrive first).
	deadline := time.Now().Add(4 * time.Second)
	for {
		if time.Now().After(deadline) {
			t.Fatal("did not receive desired_models after register")
		}
		readCtx, readCancel := context.WithTimeout(ctx, 2*time.Second)
		_, data, rerr := conn.Read(readCtx)
		readCancel()
		if rerr != nil {
			t.Fatalf("read: %v", rerr)
		}
		var env struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(data, &env); err != nil {
			continue
		}
		if env.Type != protocol.TypeDesiredModels {
			continue
		}
		var msg protocol.DesiredModelsMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			t.Fatalf("decode desired_models: %v", err)
		}
		if len(msg.Models) != 1 {
			t.Fatalf("desired_models entries = %d, want 1: %+v", len(msg.Models), msg.Models)
		}
		e := msg.Models[0]
		if e.ModelName != "gemma-4-26b" || e.DesiredBuild != aliasQAT || e.PreviousBuild != aliasFP8 {
			t.Fatalf("desired_models entry mismatch: %+v", e)
		}
		return
	}
}

// Flipping an alias's desired build via the admin upsert endpoint fans out a
// fresh desired_models to every connected provider already serving the alias.
// This is the only test that drives the live fan-out path (handleModelAliasUpsert
// -> fanOutDesiredModels) with a CONNECTED provider over the real WebSocket. The
// concurrent registry write-lock pressure (the SetModelCatalog goroutine) plus
// the -race detector exercise the lock discipline fanOutDesiredModels relies on:
// it must NOT nest r.mu.RLock (it collects eligible IDs inside ForEachProvider,
// which holds r.mu.RLock, then calls DesiredModelsForProvider — which re-takes
// r.mu — only AFTER the outer lock is released). Nesting those RLocks risks a
// deadlock once a writer queues between them; the 5s upsert deadline guards it.
func TestAliasUpsertFansOutDesiredModelsToConnectedProvider(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = time.Hour // don't race the desired_models read with a challenge
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	seedActiveModel(t, st, aliasFP8, "fp8")
	seedActiveModel(t, st, aliasQAT, "qat")
	// Alias initially points entirely at fp8 (no rollout in flight). The provider
	// advertises fp8, so it is a member of the alias and qualifies for fan-out.
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", DisplayName: "Gemma 4 26B", Active: true,
		DesiredBuild: aliasFP8,
	}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{MachineModel: "Mac15,8", ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: aliasFP8, ModelType: "chat", Quantization: "4bit"}},
		Backend:                 registry.BackendMLXSwift,
		Version:                 minProviderVersionForDesiredModels,
		PublicKey:               "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}

	// Drain the initial post-register desired_models (desired=fp8, no previous).
	readDesiredModels(ctx, t, conn, func(msg protocol.DesiredModelsMessage) bool {
		return len(msg.Models) == 1 && msg.Models[0].DesiredBuild == aliasFP8 && msg.Models[0].PreviousBuild == ""
	}, "initial desired_models (fp8)")

	// Now flip the rollout: desired=qat, previous=fp8, via the admin endpoint.
	// This must fan out a fresh desired_models to the connected provider without
	// the handler deadlocking.
	body, _ := json.Marshal(map[string]any{
		"alias_id":       "gemma-4-26b",
		"display_name":   "Gemma 4 26B",
		"desired_build":  aliasQAT,
		"previous_build": aliasFP8,
	})

	// Apply write-lock pressure to the registry while the fan-out runs. The old
	// fanOutDesiredModels nested r.mu.RLock (outer ForEachProvider + inner
	// DesiredModelsForProvider). A pending writer (Go's RWMutex blocks new
	// readers once a writer waits) wedged between the two RLocks deadlocks the
	// handler. A constant stream of SetModelCatalog writers makes that window
	// reliably hit, turning the latent hazard into a deterministic failure.
	stopWriters := make(chan struct{})
	writersDone := make(chan struct{})
	go func() {
		defer close(writersDone)
		for {
			select {
			case <-stopWriters:
				return
			default:
				reg.SetModelCatalog([]registry.CatalogEntry{{ID: aliasFP8}, {ID: aliasQAT}})
			}
		}
	}()

	upsertDone := make(chan int, 1)
	go func() {
		req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/aliases", bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer publish-secret")
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)
		upsertDone <- rec.Code
	}()
	select {
	case code := <-upsertDone:
		close(stopWriters)
		<-writersDone
		if code != http.StatusOK {
			t.Fatalf("alias upsert status = %d", code)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("alias upsert hung — fanOutDesiredModels likely deadlocked on a nested registry RLock")
	}

	// The provider receives the new rollout target over the live connection.
	readDesiredModels(ctx, t, conn, func(msg protocol.DesiredModelsMessage) bool {
		return len(msg.Models) == 1 &&
			msg.Models[0].ModelName == "gemma-4-26b" &&
			msg.Models[0].DesiredBuild == aliasQAT &&
			msg.Models[0].PreviousBuild == aliasFP8
	}, "post-flip desired_models (qat/fp8)")
}

// readDesiredModels reads frames from conn until a desired_models message
// satisfies match, or fails the test on timeout. Non-desired_models frames
// (trust_status, etc.) are skipped.
func readDesiredModels(
	ctx context.Context,
	t *testing.T,
	conn *websocket.Conn,
	match func(protocol.DesiredModelsMessage) bool,
	what string,
) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if time.Now().After(deadline) {
			t.Fatalf("did not receive %s", what)
		}
		readCtx, readCancel := context.WithTimeout(ctx, 2*time.Second)
		_, data, rerr := conn.Read(readCtx)
		readCancel()
		if rerr != nil {
			t.Fatalf("read %s: %v", what, rerr)
		}
		var env struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(data, &env); err != nil || env.Type != protocol.TypeDesiredModels {
			continue
		}
		var msg protocol.DesiredModelsMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			t.Fatalf("decode %s: %v", what, err)
		}
		if match(msg) {
			return
		}
		// A desired_models that doesn't match yet (e.g. stale) — keep reading.
	}
}

// The HTTP upsert path persists lineage: finishing a rollout (previous cleared)
// moves the old build into retired_builds, and the registry gate then matches a
// returning provider that only advertises the retired build.
func TestAliasUpsertRecordsRetiredLineage(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	seedActiveModel(t, st, aliasFP8, "fp8")
	seedActiveModel(t, st, aliasQAT, "qat")
	srv.SyncModelCatalog()

	post := func(body map[string]any) int {
		b, _ := json.Marshal(body)
		req := httptest.NewRequest(http.MethodPost, "/v1/admin/models/aliases", bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer publish-secret")
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)
		return rec.Code
	}

	// Rollout: desired=qat, previous=fp8. Then Step 7: clear previous.
	if code := post(map[string]any{"alias_id": "gemma-4-26b", "desired_build": aliasQAT, "previous_build": aliasFP8}); code != http.StatusOK {
		t.Fatalf("rollout upsert = %d", code)
	}
	if code := post(map[string]any{"alias_id": "gemma-4-26b", "desired_build": aliasQAT}); code != http.StatusOK {
		t.Fatalf("retirement upsert = %d", code)
	}
	saved, _, _ := st.GetModelAlias("gemma-4-26b")
	if len(saved.RetiredBuilds) != 1 || saved.RetiredBuilds[0] != aliasFP8 {
		t.Fatalf("fp8 should be in retired lineage, got %v", saved.RetiredBuilds)
	}

	// The registry gate sees the lineage: a provider advertising only fp8
	// (offline through the retirement) is still told to converge to qat.
	reg.Register("p-returning", nil, &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: aliasFP8, ModelType: "gemma"}},
		Backend:  registry.BackendMLXSwift,
		Version:  minProviderVersionForDesiredModels,
	})
	entries := reg.DesiredModelsForProvider("p-returning")
	if len(entries) != 1 || entries[0].DesiredBuild != aliasQAT {
		t.Fatalf("returning provider should be told qat via lineage, got %+v", entries)
	}
}

// Deleting an alias fans the post-delete desired state out to the fleet. A
// provider whose ONLY desired entry came from the deleted alias must receive an
// EMPTY desired_models — that is what marks its in-flight prefetch stale.
func TestAliasDeleteFansOutEmptyDesiredModels(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = time.Hour
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	seedActiveModel(t, st, aliasFP8, "fp8")
	seedActiveModel(t, st, aliasQAT, "qat")
	if err := st.UpsertModelAlias(&store.ModelAlias{
		AliasID: "gemma-4-26b", Active: true,
		DesiredBuild: aliasQAT, PreviousBuild: aliasFP8,
	}); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()

	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	regMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{MachineModel: "Mac15,8", ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: aliasFP8, ModelType: "chat", Quantization: "4bit"}},
		Backend:                 registry.BackendMLXSwift,
		Version:                 minProviderVersionForDesiredModels,
		PublicKey:               "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}

	// Initial post-register desired_models: the rollout entry.
	readDesiredModels(ctx, t, conn, func(msg protocol.DesiredModelsMessage) bool {
		return len(msg.Models) == 1 && msg.Models[0].DesiredBuild == aliasQAT
	}, "initial desired_models (qat)")

	// Delete the alias via the admin endpoint.
	del := httptest.NewRequest(http.MethodDelete, "/v1/admin/models/aliases/gemma-4-26b", nil)
	del.Header.Set("Authorization", "Bearer publish-secret")
	delRec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(delRec, del)
	if delRec.Code != http.StatusOK {
		t.Fatalf("delete status = %d body=%s", delRec.Code, delRec.Body.String())
	}

	// The provider's only desired entry came from the deleted alias → it must
	// receive an EMPTY desired_models (not silence).
	readDesiredModels(ctx, t, conn, func(msg protocol.DesiredModelsMessage) bool {
		return len(msg.Models) == 0
	}, "post-delete empty desired_models")
}
