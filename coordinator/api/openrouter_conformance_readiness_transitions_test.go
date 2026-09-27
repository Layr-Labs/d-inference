package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Registration is the existing authenticated metadata mutation seam; there is
// no fabricated readiness endpoint. The manifest and file HEAD checks go only
// to an owned loopback fixture, never a real artifact/CDN.
func TestOpenRouterConformanceReadinessFeed(t *testing.T) {
	const publishingKey = "fixture-only-publishing-key"
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", publishingKey)
	f := newORFixture(t, true)
	manifest := validTestManifest()
	manifest.ModelID = f.model
	manifest.R2Prefix = modelR2Prefix(f.model, "v1")
	var manifestReads atomic.Int32
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/"+manifest.R2Prefix+"/manifest.json":
			manifestReads.Add(1)
			writeJSON(w, 200, manifest)
		case r.Method == http.MethodHead && r.URL.Path == "/"+manifest.R2Prefix+"/config.json":
			w.Header().Set("Content-Length", "123")
			w.WriteHeader(200)
		default:
			http.NotFound(w, r)
		}
	}))
	defer cdn.Close()
	t.Setenv("MODEL_REGISTRY_CDN_BASE_URL", cdn.URL)
	request := func(ready bool) registerModelRequest {
		return registerModelRequest{
			ModelID: f.model, Version: "v1", DisplayName: "Synthetic transition", Family: "fixture", Architecture: "dense", Quantization: "4bit", MaxContextLength: 8192, MaxOutputLength: 2048, MinRAMGB: 1, Capabilities: []string{"tools", "reasoning"}, Metadata: map[string]any{"openrouter_is_ready": ready, huggingFaceIDMetadataKey: "fixture/conformance"}, Promote: true, InputPrice: 50_000, OutputPrice: 200_000,
			HuggingFaceArtifact: &store.HuggingFaceArtifact{RepoID: "fixture/conformance", Revision: strings.Repeat("1", 40)},
		}
	}
	mutate := func(key string, ready bool) int {
		t.Helper()
		req, err := http.NewRequestWithContext(f.ctx, http.MethodPost, f.ts.URL+"/v1/admin/models/register", bytes.NewReader(orJSON(t, request(ready))))
		if err != nil {
			t.Fatal(err)
		}
		if key != "" {
			req.Header.Set("Authorization", "Bearer "+key)
		}
		resp, err := f.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		orReadBody(t, resp)
		return resp.StatusCode
	}
	feed := func() ([]byte, bool) {
		t.Helper()
		req, err := http.NewRequestWithContext(f.ctx, http.MethodGet, f.ts.URL+"/v1/models/openrouter", nil)
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Authorization", "Bearer "+f.keys[orAccount])
		resp, err := f.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		raw := orReadBody(t, resp)
		if resp.StatusCode != 200 {
			t.Fatal(resp.StatusCode)
		}
		var result types.OpenRouterModelsResponse
		if err = json.Unmarshal(raw, &result); err != nil {
			t.Fatal(err)
		}
		found := false
		ready := false
		for _, model := range result.Data {
			if model.ID == f.model || model.ID == "conformance-retired" {
				t.Fatal("concrete/retired build leaked")
			}
			if model.ID == f.alias {
				found = true
				ready = model.IsReady
				if model.OpenRouter == nil || model.OpenRouter.Slug != f.alias {
					t.Fatal("alias changed")
				}
			}
		}
		if !found {
			t.Fatal("staged alias must stay visible")
		}
		return raw, ready
	}
	t.Run("unauthenticated_mutation_rejected", func(t *testing.T) {
		if status := mutate("", false); status != 401 {
			t.Fatalf("status=%d", status)
		}
		if manifestReads.Load() != 0 {
			t.Fatal("unauthenticated request fetched manifest")
		}
		_, ready := feed()
		if !ready {
			t.Fatal("unauthorized mutation changed readiness")
		}
	})
	t.Run("consumer_key_cannot_publish", func(t *testing.T) {
		if status := mutate(f.keys[orAccount], false); status != 401 {
			t.Fatalf("status=%d", status)
		}
		if manifestReads.Load() != 0 {
			t.Fatal("consumer request fetched manifest")
		}
	})
	for _, state := range []struct {
		name  string
		ready bool
	}{{"staged", false}, {"ready", true}, {"restaged", false}} {
		t.Run(state.name, func(t *testing.T) {
			if status := mutate(publishingKey, state.ready); status != 200 {
				t.Fatalf("metadata registration status=%d", status)
			}
			first, ready := feed()
			second, again := feed()
			if ready != state.ready || again != state.ready || !bytes.Equal(first, second) {
				t.Fatalf("readiness transition/cached identity got=%v,%v want=%v", ready, again, state.ready)
			}
			// No provider is online. Ready is launch metadata, not load/serve evidence.
			if f.srv.registry.ProviderCount() != 0 {
				t.Fatal("unexpected provider")
			}
			t.Logf("OR_READINESS {\"phase\":%q,\"feed_ready\":%t,\"alias_visible\":true,\"online_providers\":0,\"actual_load_serve\":\"not_run\"}", state.name, ready)
		})
	}
	if manifestReads.Load() != 3 {
		t.Fatalf("manifest reads=%d", manifestReads.Load())
	}
}

func TestOpenRouterConformanceReadinessCapabilities(t *testing.T) {
	f := newORModelFixture(t, true, orIncidentBuild, orIncidentAlias)
	p := f.provider("0.9.0")
	requests := 0
	charges := 0
	check := func(t *testing.T, phase, choice string, allowed bool) {
		t.Helper()
		body := orIncidentRequest(t, orIncidentAuto)
		if choice == "named" {
			body["tool_choice"] = map[string]any{"type": "function", "function": map[string]any{"name": "get_current_weather"}}
		} else {
			body["tool_choice"] = choice
		}
		before := p.count.Load()
		ch, cancel := f.startRawChat(f.keys[orAccount], orJSON(t, body))
		defer cancel()
		requests++
		if allowed {
			r := p.next()
			p.chunk(r, orIncidentCalls(orWeatherCall())+orIncidentEnd("tool_calls"))
			p.complete(r)
		}
		result := f.response(ch)
		if allowed {
			o, e := orObserve(f.ctx, result.resp, result.start, result.headersNS)
			if v := orWeatherScenario(o, e, choice); !v.ScenarioValid {
				t.Fatalf("%+v %v", v, e)
			}
			charges++
			f.settled(orAccount, int64(charges)*orCost, charges)
			if p.count.Load() != before+1 {
				t.Fatal("allowed request attempts")
			}
		} else {
			raw := orReadBody(t, result.resp)
			if result.resp.StatusCode != 400 || !json.Valid(raw) || !strings.Contains(string(raw), "inference-enforced tool_choice (required/named) is not supported") {
				t.Fatalf("capability fence status=%d", result.resp.StatusCode)
			}
			if p.count.Load() != before {
				t.Fatal("rejected request dispatched")
			}
			f.settled(orAccount, int64(charges)*orCost, charges)
		}
		t.Logf("OR_READINESS {\"phase\":%q,\"choice\":%q,\"allowed\":%t,\"dispatch_delta\":%d,\"actual_load_serve\":\"not_run\"}", phase, choice, allowed, p.count.Load()-before)
	}
	legacy := func() {
		yes := true
		p.write(protocol.ModelsUpdateMessage{Type: protocol.TypeModelsUpdate, Models: []protocol.ModelInfo{{ID: f.model, WeightHash: testHash, ModelType: "nemotron_h", Quantization: "4bit", TemplateRenderOK: &yes}}})
		// ModelsUpdate is synchronous in the coordinator reader. Ping orders that
		// frame only; it is never used to claim async billing completion.
		if err := p.conn.Ping(f.ctx); err != nil {
			t.Fatal(err)
		}
	}
	for _, phase := range []struct {
		name       string
		transition func()
		forced     bool
	}{
		{"legacy_initial", legacy, false},
		{"bad_hash_cannot_enable", func() {
			yes := true
			p.write(protocol.ModelsUpdateMessage{Type: protocol.TypeModelsUpdate, Models: []protocol.ModelInfo{{ID: f.model, WeightHash: strings.Repeat("f", 64), ModelType: "nemotron_h", TemplateRenderOK: &yes}}, ToolConstraintProtocol: 1, ToolConstraintModels: []string{f.model}})
			if err := p.conn.Ping(f.ctx); err != nil {
				t.Fatal(err)
			}
		}, false},
		{"advertised", func() { p.advertiseTools(true) }, true},
		{"legacy_omission_preserves", legacy, true},
		{"revoked", func() { p.advertiseTools(false) }, false},
		{"wrong_model_cannot_enable", func() {
			yes := true
			p.write(protocol.ModelsUpdateMessage{Type: protocol.TypeModelsUpdate, Models: []protocol.ModelInfo{{ID: f.model, WeightHash: testHash, ModelType: "nemotron_h", TemplateRenderOK: &yes}}, ToolConstraintProtocol: 1, ToolConstraintModels: []string{"different-model"}})
			if err := p.conn.Ping(f.ctx); err != nil {
				t.Fatal(err)
			}
		}, false},
		{"legacy_after_revocation", legacy, false},
	} {
		phase.transition()
		for _, choice := range []string{"auto", "required", "named"} {
			t.Run(phase.name+"/"+choice, func(t *testing.T) { check(t, phase.name, choice, choice == "auto" || phase.forced) })
		}
	}
	if requests != 21 || charges != 11 {
		t.Fatalf("request/settlement counts=%d/%d", requests, charges)
	}
	orNoCancel(t, p)
}
