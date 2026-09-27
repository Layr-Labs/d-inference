package api

import (
	"encoding/json"
	"errors"
	"io"
	"strings"
)

// This verdict must not collapse task success into HTTP/stream success. The
// fixture/model qualification labels cannot become PASS from synthetic calls.
type orScenarioVerdict struct {
	TransportValid     bool   `json:"transport_valid"`
	ScenarioValid      bool   `json:"scenario_valid"`
	Reason             string `json:"reason"`
	Calls              int    `json:"calls"`
	ContentPresent     bool   `json:"content_present"`
	ModelQualification string `json:"model_qualification"`
}

// This expectation is independent of the response builders. It is the authored
// Boston scenario, not a general claim that auto must always select a tool.
func orWeatherScenario(o orObservation, transportErr error, choice string) orScenarioVerdict {
	v := orScenarioVerdict{TransportValid: transportErr == nil && o.Terminal == "success", Reason: "transport_invalid", Calls: len(o.Tools), ContentPresent: o.Content != "", ModelQualification: "not_run"}
	fail := func(reason string) orScenarioVerdict { v.Reason = reason; return v }
	if !v.TransportValid {
		return v
	}
	if o.ToolError != "" {
		return fail(o.ToolError)
	}
	if choice == "none" {
		if len(o.Tools) != 0 {
			return fail("unexpected_tool_call")
		}
		if o.Finish != "stop" {
			return fail("unexpected_finish")
		}
		v.ScenarioValid = true
		v.Reason = "expected_no_call"
		return v
	}
	if len(o.Tools) == 0 {
		return fail("expected_tool_call_missing")
	}
	if len(o.Tools) != 1 {
		return fail("wrong_cardinality")
	}
	c := o.Tools[0]
	if c.Index != 0 {
		return fail("wrong_tool_index")
	}
	if c.ID == "" {
		return fail("missing_call_id")
	}
	if c.Type != "function" {
		return fail("wrong_tool_type")
	}
	if c.Name != "get_current_weather" {
		return fail("wrong_function")
	}
	if o.Finish != "tool_calls" {
		return fail("wrong_finish")
	}
	args, err := orStrictStringObject(c.Arguments)
	if err != nil {
		return fail("invalid_arguments")
	}
	if len(args) != 2 {
		return fail("argument_keys")
	}
	location, locationOK := args["location"]
	unit, unitOK := args["unit"]
	if !locationOK || !unitOK {
		return fail("argument_keys")
	}
	switch strings.ToLower(strings.TrimSpace(location)) {
	case "boston, ma", "boston, massachusetts":
	default:
		return fail("wrong_location")
	}
	if unit != "fahrenheit" {
		return fail("wrong_unit")
	}
	v.ScenarioValid = true
	v.Reason = "expected_tool_call"
	return v
}

// json.Unmarshal into a map silently accepts duplicate keys. The scenario
// rejects those, non-string values, multiple JSON values, and unfinished input.
func orStrictStringObject(raw string) (map[string]string, error) {
	d := json.NewDecoder(strings.NewReader(raw))
	token, err := d.Token()
	if err != nil || token != json.Delim('{') {
		return nil, errors.New("arguments must be an object")
	}
	out := map[string]string{}
	for d.More() {
		key, err := d.Token()
		if err != nil {
			return nil, err
		}
		name, ok := key.(string)
		if !ok {
			return nil, errors.New("invalid key")
		}
		if _, duplicate := out[name]; duplicate {
			return nil, errors.New("duplicate key")
		}
		value, err := d.Token()
		if err != nil {
			return nil, err
		}
		text, ok := value.(string)
		if !ok {
			return nil, errors.New("argument value must be a string")
		}
		out[name] = text
	}
	if token, err = d.Token(); err != nil || token != json.Delim('}') {
		return nil, errors.New("unfinished object")
	}
	if _, err = d.Token(); !errors.Is(err, io.EOF) {
		return nil, errors.New("trailing JSON")
	}
	return out, nil
}
