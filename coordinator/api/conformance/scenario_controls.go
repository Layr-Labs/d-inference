package conformance

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"testing"
	"time"
)

func (s Suite) TestOpenRouterConformanceScenario(t *testing.T) {
	end := orIncidentEnd("tool_calls")
	bad := func(name, args string) string {
		return orIncidentCalls(orIncidentTool(0, "call-fixture-weather", name, args)) + end
	}
	changed := orIncidentCalls(orIncidentTool(0, "first", "get_current_weather", `{"location":`)) + orIncidentCalls(orIncidentTool(0, "second", "", `"Boston, MA","unit":"fahrenheit"}`)) + end
	for _, tc := range []struct {
		name, wire, choice, reason string
		valid, transport           bool
	}{
		{"weather_call", orIncidentCalls(orWeatherCall()) + end, "auto", "expected_tool_call", true, true},
		{"permitted_prefix_off", orIncidentFrame(map[string]any{"content": "Let me check Boston."}, nil) + orIncidentCalls(orWeatherCall()) + end, "auto", "expected_tool_call", true, true},
		{"required_control", orIncidentCalls(orWeatherCall()) + end, "required", "expected_tool_call", true, true},
		{"named_control", orIncidentCalls(orWeatherCall()) + end, "named", "expected_tool_call", true, true},
		{"none_control", orIncidentFrame(map[string]any{"content": "Synthetic plain answer."}, nil) + orIncidentEnd("stop"), "none", "expected_no_call", true, true},
		{"none_rejects_call", orIncidentCalls(orWeatherCall()) + end, "none", "unexpected_tool_call", false, true},
		{"refusal_39", orIncidentFrame(map[string]any{"content": orRefusal39}, nil) + orIncidentEnd("stop"), "auto", "expected_tool_call_missing", false, true},
		{"refusal_43", orIncidentFrame(map[string]any{"content": orRefusal43}, nil) + orIncidentEnd("stop"), "auto", "expected_tool_call_missing", false, true},
		{"wrong_function", bad("other", `{"location":"Boston, MA","unit":"fahrenheit"}`), "auto", "wrong_function", false, true},
		{"wrong_location", bad("get_current_weather", `{"location":"Paris","unit":"fahrenheit"}`), "auto", "wrong_location", false, true},
		{"wrong_unit", bad("get_current_weather", `{"location":"Boston, MA","unit":"celsius"}`), "auto", "wrong_unit", false, true},
		{"invalid_enum", bad("get_current_weather", `{"location":"Boston, MA","unit":"kelvin"}`), "auto", "wrong_unit", false, true},
		{"malformed_json", bad("get_current_weather", `oops`), "auto", "invalid_arguments", false, true},
		{"truncated_json", bad("get_current_weather", `{"location":`), "auto", "invalid_arguments", false, true},
		{"duplicate_key", bad("get_current_weather", `{"location":"Paris","location":"Boston, MA","unit":"fahrenheit"}`), "auto", "invalid_arguments", false, true},
		{"trailing_json", bad("get_current_weather", `{"location":"Boston, MA","unit":"fahrenheit"}{}`), "auto", "invalid_arguments", false, true},
		{"null_argument", bad("get_current_weather", `{"location":null,"unit":"fahrenheit"}`), "auto", "invalid_arguments", false, true},
		{"missing_key", bad("get_current_weather", `{"location":"Boston, MA"}`), "auto", "argument_keys", false, true},
		{"extra_key", bad("get_current_weather", `{"location":"Boston, MA","unit":"fahrenheit","extra":"x"}`), "auto", "argument_keys", false, true},
		{"missing_id", orIncidentCalls(orIncidentTool(0, "", "get_current_weather", `{}`)) + end, "auto", "missing_call_id", false, true},
		{"changed_id", changed, "auto", "changed_call_id", false, true},
		{"duplicate_id", orIncidentCalls(orWeatherCall(), orIncidentTool(1, "call-fixture-weather", "get_current_weather", `{}`)) + end, "auto", "duplicate_call_id", false, true},
		{"extra_call", orIncidentCalls(orWeatherCall(), orIncidentTool(1, "second", "get_current_weather", `{}`)) + end, "auto", "wrong_cardinality", false, true},
		{"wrong_index", orIncidentCalls(orIncidentTool(1, "call", "get_current_weather", `{}`)) + end, "auto", "wrong_tool_index", false, true},
		{"negative_index", orIncidentCalls(orIncidentTool(-1, "call", "get_current_weather", `{}`)) + end, "auto", "invalid_tool_index", false, true},
		{"wrong_choice_index", strings.Replace(orIncidentCalls(orWeatherCall()), `"index":0,"delta"`, `"index":1,"delta"`, 1) + end, "auto", "transport_invalid", false, false},
		{"call_with_stop", orIncidentCalls(orWeatherCall()) + orIncidentEnd("stop"), "auto", "wrong_finish", false, true},
		{"finish_without_call", orIncidentFrame(map[string]any{"content": "no call"}, nil) + end, "auto", "expected_tool_call_missing", false, true},
		{"markup_is_prose", orIncidentFrame(map[string]any{"content": "<tool_call>get_current_weather</tool_call>"}, nil) + orIncidentEnd("stop"), "auto", "expected_tool_call_missing", false, true},
		{"post_finish_call", orIncidentCalls(orWeatherCall()) + orIncidentFrame(map[string]any{}, "tool_calls") + orIncidentCalls(orWeatherCall()) + "data: [DONE]\n\n", "auto", "transport_invalid", false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			// Field order is JSON implementation-defined; construct wrong choice explicitly.
			if tc.name == "wrong_choice_index" {
				tc.wire = strings.Replace(tc.wire, `"finish_reason":null,"index":0`, `"finish_reason":null,"index":1`, 1)
			}
			o, err := orObserve(context.Background(), orResponse(io.NopCloser(strings.NewReader(tc.wire))), time.Now(), nil)
			v := orWeatherScenario(o, err, tc.choice)
			if v.TransportValid != tc.transport || v.ScenarioValid != tc.valid || v.Reason != tc.reason {
				t.Fatalf("verdict=%+v err=%v", v, err)
			}
			if tc.name == "permitted_prefix_off" && o.Content != "Let me check Boston." {
				t.Fatal("pre-call content suppressed")
			}
			b, _ := json.Marshal(v)
			t.Logf("OR_SCENARIO %s", b)
		})
	}
	for _, mutate := range []struct {
		name, reason string
		change       func(map[string]any)
	}{
		{"missing_index", "missing_tool_index", func(c map[string]any) { delete(c, "index") }},
		{"wrong_type", "wrong_tool_type", func(c map[string]any) { c["type"] = "other" }},
		{"missing_type", "wrong_tool_type", func(c map[string]any) { delete(c, "type") }},
	} {
		t.Run(mutate.name, func(t *testing.T) {
			c := orWeatherCall()
			mutate.change(c)
			o, e := orObserve(context.Background(), orResponse(io.NopCloser(strings.NewReader(orIncidentCalls(c)+end))), time.Now(), nil)
			v := orWeatherScenario(o, e, "auto")
			if !v.TransportValid || v.ScenarioValid || v.Reason != mutate.reason {
				t.Fatalf("%+v %v", v, e)
			}
		})
	}
}

func (s Suite) TestOpenRouterConformanceScenarioFragmentation(t *testing.T) {
	const args = `{"location":"Boston, MA","unit":"fahrenheit"}`
	for split := 0; split <= len(args); split++ {
		t.Run(fmt.Sprintf("split_%02d", split), func(t *testing.T) {
			first := orIncidentTool(0, "call-fixture-weather", "get_current_weather", args[:split])
			rest := map[string]any{"index": 0, "function": map[string]any{"arguments": args[split:]}}
			wire := orIncidentFrame(map[string]any{"content": "Checking 🌊 Boston."}, nil) + orIncidentCalls(first) + orIncidentCalls(rest) + orIncidentEnd("tool_calls")
			o, e := orObserve(context.Background(), orResponse(io.NopCloser(orByteReader{strings.NewReader(wire)})), time.Now(), nil)
			if v := orWeatherScenario(o, e, "auto"); !v.ScenarioValid {
				t.Fatalf("split %d: %+v %v", split, v, e)
			}
			if o.Content != "Checking 🌊 Boston." || o.Tools[0].Arguments != args {
				t.Fatal("fragment data changed")
			}
		})
	}
}

func (s Suite) TestOpenRouterConformanceScenarioBounds(t *testing.T) {
	for _, tc := range []struct{ name, wire string }{
		{"oversize_call_id", orIncidentCalls(orIncidentTool(0, strings.Repeat("x", 257), "get_current_weather", `{}`)) + orIncidentEnd("tool_calls")},
		{"oversize_name", orIncidentCalls(orIncidentTool(0, "call", strings.Repeat("x", 257), `{}`)) + orIncidentEnd("tool_calls")},
		{"accumulated_argument_bound", orIncidentCalls(orIncidentTool(0, "call", "get_current_weather", strings.Repeat("x", 9000))) + orIncidentCalls(map[string]any{"index": 0, "function": map[string]any{"arguments": strings.Repeat("x", 9000)}}) + orIncidentEnd("tool_calls")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			o, e := orObserve(context.Background(), orResponse(io.NopCloser(strings.NewReader(tc.wire))), time.Now(), nil)
			if e == nil || orWeatherScenario(o, e, "auto").ScenarioValid {
				t.Fatal("unbounded tool payload passed")
			}
		})
	}
	t.Run("split_unicode_arguments", func(t *testing.T) {
		c := orIncidentTool(0, "call-fixture-weather", "get_current_weather", `{"location":" Boston, MA ","unit":"fahrenheit"}`)
		o, e := orObserve(context.Background(), orResponse(io.NopCloser(orByteReader{strings.NewReader(orIncidentCalls(c) + orIncidentEnd("tool_calls"))})), time.Now(), nil)
		if v := orWeatherScenario(o, e, "auto"); !v.ScenarioValid {
			t.Fatalf("%+v %v", v, e)
		}
	})
}

func (s Suite) TestOpenRouterConformanceScenarioChoiceShape(t *testing.T) {
	for _, name := range []string{"missing_choice_index", "null_choice_index", "duplicate_choice_zero"} {
		t.Run(name, func(t *testing.T) {
			wire := orIncidentCalls(orWeatherCall())
			var event map[string]any
			if err := json.Unmarshal([]byte(strings.TrimSpace(strings.TrimPrefix(wire, "data: "))), &event); err != nil {
				t.Fatal(err)
			}
			choices := event["choices"].([]any)
			choice := choices[0].(map[string]any)
			switch name {
			case "missing_choice_index":
				delete(choice, "index")
			case "null_choice_index":
				choice["index"] = nil
			case "duplicate_choice_zero":
				event["choices"] = append(choices, choice)
			}
			data, err := json.Marshal(event)
			if err != nil {
				t.Fatal(err)
			}
			o, e := orObserve(context.Background(), orResponse(io.NopCloser(strings.NewReader("data: "+string(data)+"\n\n"+orIncidentEnd("tool_calls")))), time.Now(), nil)
			if v := orWeatherScenario(o, e, "auto"); v.TransportValid || v.ScenarioValid || e == nil {
				t.Fatalf("invalid choice shape passed: %+v", v)
			}
		})
	}
}
