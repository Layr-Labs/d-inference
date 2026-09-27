package api

import (
	"encoding/base64"
	"encoding/json"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"
)

func TestOpenRouterConformanceIncidentEnvelope(t *testing.T) {
	cases := []struct {
		name, original string
		change         func(map[string]any)
	}{
		{"off_omitted", orIncidentOmitted, nil},
		{"off_auto", orIncidentAuto, nil},
		{"on_auto_authored", orIncidentAuto, func(b map[string]any) { b["reasoning"] = map[string]any{"enabled": true} }},
		{"on_none_authored", orIncidentAuto, func(b map[string]any) { b["reasoning"] = map[string]any{"enabled": true}; b["tool_choice"] = "none" }},
		{"on_required_authored", orIncidentAuto, func(b map[string]any) {
			b["reasoning"] = map[string]any{"enabled": true}
			b["tool_choice"] = "required"
		}},
		{"on_named_authored", orIncidentAuto, func(b map[string]any) {
			b["reasoning"] = map[string]any{"enabled": true}
			b["tool_choice"] = map[string]any{"type": "function", "function": map[string]any{"name": "get_current_weather"}}
		}},
		{"strict_false_authored", orIncidentOmitted, func(b map[string]any) { orIncidentFunction(b)["strict"] = false }},
		{"strict_absent_authored", orIncidentOmitted, func(b map[string]any) { delete(orIncidentFunction(b), "strict") }},
		{"nested_false_conflict_authored", orIncidentAuto, func(b map[string]any) {
			b["enable_thinking"] = true
			b["chat_template_kwargs"] = map[string]any{"enable_thinking": true}
		}},
		{"nested_true_conflict_authored", orIncidentAuto, func(b map[string]any) {
			b["reasoning"] = map[string]any{"enabled": true, "effort": "none"}
			b["chat_template_kwargs"] = map[string]any{"enable_thinking": false}
		}},
		{"kwargs_false_authored", orIncidentAuto, func(b map[string]any) {
			delete(b, "reasoning")
			b["chat_template_kwargs"] = map[string]any{"enable_thinking": false}
		}},
		{"plain_thinking_alias_authored", orIncidentAuto, func(b map[string]any) { delete(b, "reasoning"); b["thinking"] = false }},
		{"effort_none_authored", orIncidentAuto, func(b map[string]any) { b["reasoning"] = map[string]any{"effort": "none"} }},
		{"explicit_sampling_zero_authored", orIncidentAuto, func(b map[string]any) { b["temperature"] = float64(0); b["top_p"] = float64(1) }},
		{"single_call_policy_authored", orIncidentAuto, func(b map[string]any) { b["parallel_tool_calls"] = false }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newORModelFixture(t, true, orIncidentBuild, orIncidentAlias)
			p := f.provider("0.9.0")
			body := orIncidentRequest(t, tc.original)
			if tc.change != nil {
				tc.change(body)
			}
			// All controls have qualified synthetic advertisement. No actual native load.
			p.advertiseTools(true)
			before := time.Now().UTC().Format(time.DateOnly)
			ch, cancel := f.startRawChat(f.keys[orAccount], orJSON(t, body))
			defer cancel()
			dispatched := p.next()
			orAssertIncidentEnvelope(t, body, dispatched.body, before, time.Now().UTC().Format(time.DateOnly))
			choice := "auto"
			if s, ok := body["tool_choice"].(string); ok {
				choice = s
			}
			wire := orIncidentCalls(orWeatherCall()) + orIncidentEnd("tool_calls")
			if choice == "none" {
				wire = orIncidentFrame(map[string]any{"content": "Authored no-call control."}, nil) + orIncidentEnd("stop")
			}
			p.chunk(dispatched, wire)
			p.complete(dispatched)
			result := f.response(ch)
			o, err := orObserve(f.ctx, result.resp, result.start, result.headersNS)
			v := orWeatherScenario(o, err, choice)
			if !v.ScenarioValid {
				t.Fatalf("authored result: %+v %v", v, err)
			}
			if o.Model != orIncidentAlias || p.count.Load() != 1 {
				t.Fatal("identity/attempt mismatch")
			}
			orNoCancel(t, p)
			f.settled(orAccount, orCost, 1)
			report := struct {
				Case         string            `json:"case"`
				Envelope     bool              `json:"envelope_valid"`
				ModelWrapper string            `json:"model_wrapper"`
				Verdict      orScenarioVerdict `json:"verdict"`
			}{tc.name, true, "synthetic_alias_and_concrete_build; captured_body_omits_model", v}
			b, _ := json.Marshal(report)
			t.Logf("OR_INCIDENT %s", b)
		})
	}
}

func orIncidentFunction(body map[string]any) map[string]any {
	return body["tools"].([]any)[0].(map[string]any)["function"].(map[string]any)
}

func orAssertIncidentEnvelope(t *testing.T, sent, received map[string]any, before, after string) {
	t.Helper()
	// Only these production transformations are authorized by the current code:
	// alias -> concrete build; missing max_tokens -> catalog output bound2048;
	// coordinator-owned UTC prompt date and protocol-0 per-attempt cache buster.
	// Everything else must match exactly; the original body remains unchanged.
	expected := map[string]any{}
	for k, v := range sent {
		expected[k] = v
	}
	expected["model"] = orIncidentBuild
	if _, present := expected["max_tokens"]; !present {
		expected["max_tokens"] = float64(2048)
	}
	date, ok := received["_darkbloom_prompt_date"].(string)
	if !ok || (date != before && date != after) {
		t.Fatal("invalid coordinator prompt date")
	}
	expected["_darkbloom_prompt_date"] = date
	key, ok := received["prompt_cache_key"].(string)
	nonce, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(key, "darkbloom-uncached-"))
	if !ok || !strings.HasPrefix(key, "darkbloom-uncached-") || err != nil || len(nonce) != 16 {
		t.Fatal("invalid legacy cache-isolation wrapper")
	}
	expected["prompt_cache_key"] = key
	if !reflect.DeepEqual(expected, received) {
		var fields []string
		for k, v := range expected {
			if other, ok := received[k]; !ok || !reflect.DeepEqual(v, other) {
				fields = append(fields, k)
			}
		}
		for k := range received {
			if _, ok := expected[k]; !ok {
				fields = append(fields, k)
			}
		}
		sort.Strings(fields)
		t.Fatalf("synthetic provider envelope differs in fields: %v", fields)
	}
}

func TestOpenRouterConformanceIncidentRefusal(t *testing.T) {
	for _, original := range []struct{ name, body string }{{"off_omitted", orIncidentOmitted}, {"off_auto", orIncidentAuto}} {
		for _, refusal := range []struct{ name, text string }{{"39", orRefusal39}, {"43", orRefusal43}} {
			t.Run(original.name+"/refusal_"+refusal.name, func(t *testing.T) {
				f := newORModelFixture(t, true, orIncidentBuild, orIncidentAlias)
				p := f.provider("0.9.0")
				body := orIncidentRequest(t, original.body)
				before := time.Now().UTC().Format(time.DateOnly)
				ch, cancel := f.startRawChat(f.keys[orAccount], orJSON(t, body))
				defer cancel()
				r := p.next()
				orAssertIncidentEnvelope(t, body, r.body, before, time.Now().UTC().Format(time.DateOnly))
				p.chunk(r, orIncidentFrame(map[string]any{"content": refusal.text}, nil)+orIncidentEnd("stop"))
				p.complete(r)
				result := f.response(ch)
				o, err := orObserve(f.ctx, result.resp, result.start, result.headersNS)
				v := orWeatherScenario(o, err, "auto")
				if !v.TransportValid || v.ScenarioValid || v.Reason != "expected_tool_call_missing" || o.Content != refusal.text {
					t.Fatalf("refusal false green: %+v %v", v, err)
				}
				orNoCancel(t, p)
				f.settled(orAccount, orCost, 1)
				report := struct {
					Case    string            `json:"case"`
					Framing string            `json:"framing"`
					Usage   string            `json:"usage"`
					Verdict orScenarioVerdict `json:"verdict"`
				}{original.name + "/" + refusal.name, "authored_SSE; historical_display_has_no_delimiters_or_DONE", "synthetic_10_plus_10; suffix39_43_labels_historical_variant", v}
				b, _ := json.Marshal(report)
				t.Logf("OR_INCIDENT %s", b)
			})
		}
	}
}
