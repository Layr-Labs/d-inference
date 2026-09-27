package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestOpenRouterConformanceAuth(t *testing.T) {
	f := newORFixture(t, true)
	past := time.Now().Add(-time.Hour)
	expired, _, err := f.st.CreateAPIKey(orAccount, store.APIKeyCreate{ExpiresAt: &past})
	if err != nil {
		t.Fatal(err)
	}
	disabled, record, err := f.st.CreateAPIKey(orAccount, store.APIKeyCreate{})
	if err != nil {
		t.Fatal(err)
	}
	record.Disabled = true
	if _, err = f.st.UpdateAPIKey(orAccount, record.ID, *record); err != nil {
		t.Fatal(err)
	}
	for _, endpoint := range []string{"/v1/models/openrouter", "/v1/chat/completions"} {
		for _, tc := range []struct{ name, key string }{{"missing", ""}, {"invalid", "invalid-fixture-key"}, {"disabled", disabled}, {"expired", expired}} {
			t.Run(endpoint+"/"+tc.name, func(t *testing.T) {
				method := http.MethodGet
				if strings.Contains(endpoint, "chat") {
					method = http.MethodPost
				}
				req, err := http.NewRequestWithContext(f.ctx, method, f.ts.URL+endpoint, strings.NewReader(`{"model":"conformance-alias","messages":[{"role":"user","content":"fixture"}]}`))
				if err != nil {
					t.Fatal(err)
				}
				if tc.key != "" {
					req.Header.Set("Authorization", "Bearer "+tc.key)
				}
				resp, err := f.client.Do(req)
				if err != nil {
					t.Fatal(err)
				}
				body := orReadBody(t, resp)
				if resp.StatusCode != 401 || !json.Valid(body) {
					t.Fatalf("auth status=%d validJSON=%v", resp.StatusCode, json.Valid(body))
				}
			})
		}
	}
	f.settled(orAccount, 0, 0)
}

func TestOpenRouterConformanceFeed(t *testing.T) {
	f := newORFixture(t, true)
	p := f.provider("0.8.15")
	read := func() types.OpenRouterModelsResponse {
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
		body := orReadBody(t, resp)
		if resp.StatusCode != 200 {
			t.Fatalf("feed status %d", resp.StatusCode)
		}
		for _, field := range []string{`"metadata"`, `"trust_level"`, `"private_fixture_marker"`, `"must-not-leak"`, orModel, "conformance-retired"} {
			if strings.Contains(string(body), field) {
				t.Fatalf("feed leaked internal field/build %s", field)
			}
		}
		var feed types.OpenRouterModelsResponse
		if err = json.Unmarshal(body, &feed); err != nil {
			t.Fatal(err)
		}
		return feed
	}
	before := read()
	if len(before.Data) != 2 {
		t.Fatalf("feed count=%d want 2", len(before.Data))
	}
	for _, m := range before.Data {
		if m.ID != orAlias && m.ID != "conformance-staged" {
			t.Fatalf("unexpected model %s", m.ID)
		}
		if m.HuggingFaceID != "fixture/conformance" || m.OpenRouter == nil || m.OpenRouter.Slug != m.ID || m.ContextLength != 8192 || m.MaxOutputLength != 2048 {
			t.Fatalf("feed identity/schema: %+v", m)
		}
		wantQuantization := "int4"
		if m.ID == orAlias {
			wantQuantization = ""
		} // aliases intentionally omit build quantization.
		if m.Quantization != wantQuantization {
			t.Fatalf("quantization=%q want %q", m.Quantization, wantQuantization)
		}
		if !reflect.DeepEqual(m.InputModalities, []string{"text"}) || !reflect.DeepEqual(m.OutputModalities, []string{"text"}) {
			t.Fatalf("modalities: %+v", m)
		}
		if m.Pricing.Prompt != "0.00000005" || m.Pricing.Completion != "0.0000002" || m.Pricing.InputCacheRead != "0" {
			t.Fatalf("feed prices: %+v", m.Pricing)
		}
		if !reflect.DeepEqual(m.SupportedFeatures, []string{"reasoning", "tools"}) || !reflect.DeepEqual(m.SupportedSamplingParameters, []string{"temperature", "top_p", "top_k", "frequency_penalty", "presence_penalty", "repetition_penalty", "stop", "seed", "max_tokens"}) {
			t.Fatalf("capability/sampling mismatch: %+v", m)
		}
		if m.IsReady != (m.ID == orAlias) {
			t.Fatalf("staging readiness %s=%v", m.ID, m.IsReady)
		}
	}
	p.close()
	orEventually(t, func() bool { return f.srv.registry.ProviderCount() == 0 }, "provider disconnect")
	// Invalidate the read cache through the existing catalog seam so outage
	// persistence is checked against a newly constructed feed, not stale bytes.
	f.srv.SyncModelCatalog()
	after := read()
	if !reflect.DeepEqual(before, after) {
		t.Fatalf("synthetic feed changed across outage")
	}
	t.Log(`OR_REPORT {"scenario":"A2","status":200,"public_models":["conformance-alias","conformance-staged"],"outage_persistent":true}`)
}

func TestOpenRouterConformanceChat(t *testing.T) {
	for _, holds := range []bool{false, true} {
		for _, mode := range []string{"nonstream", "stream", "stream_usage"} {
			t.Run(fmt.Sprintf("holds_%t/%s", holds, mode), func(t *testing.T) {
				f := newORFixture(t, holds)
				p := f.provider("0.8.15")
				stream := mode != "nonstream"
				ch, cancel := f.startChat(f.keys[orAccount], stream, nil)
				defer cancel()
				r := p.next()
				if r.body["model"] != orModel || r.request.FirstContentBudgetMS <= 0 {
					t.Fatal("resolved build/encrypted request/SLA missing")
				}
				if holds && f.hold(orAccount) <= 0 {
					t.Fatal("service hold not acquired")
				}
				p.success(r, stream, mode == "stream_usage")
				result := f.response(ch)
				var o orObservation
				if stream {
					var err error
					o, err = orObserve(f.ctx, result.resp, result.start, result.headersNS)
					if err != nil {
						t.Fatal(err)
					}
					if o.Model != orAlias || o.Text != "héllo" || o.ID != "fixture-response" || o.Finish != "stop" {
						t.Fatalf("stream response %+v", o)
					}
					if (o.Usage != nil) != (mode == "stream_usage") {
						t.Fatalf("optional usage %+v", o.Usage)
					}
					if o.Usage != nil && *o.Usage != (orUsage{10, 10, 20}) {
						t.Fatal("stream usage mismatch")
					}
				} else {
					var body struct {
						ID, Object, Model string
						Choices           []struct {
							Message struct{ Role, Content string }
							Finish  string `json:"finish_reason"`
						}
						Usage orUsage
					}
					b := orReadBody(t, result.resp)
					if err := json.Unmarshal(b, &body); err != nil {
						t.Fatal(err)
					}
					if result.resp.StatusCode != 200 || body.ID != "fixture-response" || body.Object != "chat.completion" || body.Model != orAlias || len(body.Choices) != 1 || body.Choices[0].Message.Content != "héllo" || body.Choices[0].Finish != "stop" || body.Usage != (orUsage{10, 10, 20}) {
						t.Fatalf("nonstream response %+v status %d", body, result.resp.StatusCode)
					}
					o = orObservation{Status: 200, HeadersNS: result.headersNS, Model: orAlias, Terminal: "success", Usage: &body.Usage}
				}
				f.settled(orAccount, orCost, 1)
				records := f.st.UsageByConsumer(orAccount)
				if records[0].CostMicroUSD != orCost || records[0].PromptTokens != 10 || records[0].CompletionTokens != 10 || records[0].RequestID != r.request.RequestID {
					t.Fatalf("settled usage mismatch %+v", records)
				}
				if p.count.Load() != 1 {
					t.Fatal("unexpected internal replay")
				}
				orNoCancel(t, p)
				f.report("A3_A4_A12", o, 1, orCost, holds)
			})
		}
	}
}

func TestOpenRouterConformanceAccountSLA(t *testing.T) {
	for _, name := range []string{orAccount, "second", "conformance-exempt", "conformance-other-service"} {
		t.Run(name, func(t *testing.T) {
			f := newORFixture(t, true)
			p := f.provider("0.8.15")
			ch, cancel := f.startChat(f.keys[name], false, nil)
			defer cancel()
			r := p.next()
			selected := name == orAccount || name == "second"
			if (r.request.FirstContentBudgetMS > 0) != selected {
				t.Fatalf("selected=%v wire budget=%d", selected, r.request.FirstContentBudgetMS)
			}
			p.success(r, false, false)
			resp := f.response(ch)
			orReadBody(t, resp.resp)
			if resp.resp.StatusCode != 200 {
				t.Fatal(resp.resp.StatusCode)
			}
		})
	}
}

func TestOpenRouterConformanceDrain(t *testing.T) {
	f := newORFixture(t, true)
	f.srv.SetDraining(true)
	// Deliberate unauthenticated request proves drain's outer middleware precedence.
	ch, cancel := f.startChat("", true, nil)
	defer cancel()
	r := f.response(ch)
	body := orReadBody(t, r.resp)
	if r.resp.StatusCode != 429 || r.resp.Header.Get("Retry-After") != "3" || !json.Valid(body) {
		t.Fatalf("drain status %d retry-after %s", r.resp.StatusCode, r.resp.Header.Get("Retry-After"))
	}
	f.settled(orAccount, 0, 0)
}

func (f *orFixture) report(scenario string, o orObservation, attempts int, cost int64, holds bool) {
	f.t.Helper()
	report := struct {
		Schema         int           `json:"schema"`
		Scenario       string        `json:"scenario"`
		CallerRequests int           `json:"caller_requests"`
		Attempts       int           `json:"internal_attempts"`
		Provider       string        `json:"provider"`
		BalanceDelta   int64         `json:"balance_delta_micro_usd"`
		UsageRecords   int           `json:"usage_records"`
		Holds          bool          `json:"service_holds_enabled"`
		Outstanding    int64         `json:"outstanding_hold"`
		Observation    orObservation `json:"observation"`
	}{1, scenario, 1, attempts, "synthetic-loopback", -cost, len(f.st.UsageByConsumer(orAccount)), holds, f.hold(orAccount), o}
	b, err := json.Marshal(report)
	if err != nil {
		f.t.Fatal(err)
	}
	f.t.Logf("OR_REPORT %s", b)
}
