package protocol

import (
	"encoding/json"
	"testing"
)

func TestModelAutopilotCommandWire(t *testing.T) {
	command := ModelAutopilotMessage{Type: TypeModelAutopilot, CommandID: "command-1", LoadModelID: "model-a", UnloadModelIDs: []string{}, ExpectedResidentModels: []string{}, ExpiresAtMS: 1900000000000, LeaseSeconds: 1800}
	b, err := json.Marshal(command)
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	if err = json.Unmarshal(b, &fields); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"unload_model_ids", "expected_resident_models"} {
		if string(fields[key]) != "[]" {
			t.Fatalf("%s must be an empty array for strict Swift decode: %s", key, fields[key])
		}
	}
	var decoded ModelAutopilotMessage
	if err = json.Unmarshal(b, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.CommandID != command.CommandID || decoded.ExpiresAtMS != command.ExpiresAtMS || decoded.LeaseSeconds != 1800 {
		t.Fatalf("wire contract changed: %+v", decoded)
	}
}

func TestModelAutopilotStatusWireAndOptInOmission(t *testing.T) {
	var message ProviderMessage
	if err := json.Unmarshal([]byte(`{"type":"model_autopilot_status","command_id":"command-1","status":"succeeded","model_autopilot":{"protocol":1,"enabled":true,"cached_only":true,"min_dwell_seconds":1800,"pinned_models":[],"max_model_slots":3,"resident_models":[{"model_id":"model-a","resident_seconds":2,"idle_seconds":0,"weights_gb":12,"resident_gb":10}],"free_for_load_no_evict_gb":4,"last_command_id":"command-1","last_command_status":"succeeded"}}`), &message); err != nil {
		t.Fatal(err)
	}
	status, ok := message.Payload.(*ModelAutopilotStatusMessage)
	if !ok || status.CommandID != "command-1" || status.ModelAutopilot == nil || !status.ModelAutopilot.Enabled {
		t.Fatalf("bad status payload: %#v", message.Payload)
	}
	if got := status.ModelAutopilot.ResidentModels[0].ResidentGB; got == nil || *got != 10 {
		t.Fatalf("actual reclaim credit lost: %v", got)
	}
	var legacy RegisterMessage
	if err := json.Unmarshal([]byte(`{"type":"register","models":[],"backend":"mlx-swift"}`), &legacy); err != nil {
		t.Fatal(err)
	}
	if legacy.ModelAutopilot != nil {
		t.Fatal("missing opt-in must remain disabled")
	}
}
