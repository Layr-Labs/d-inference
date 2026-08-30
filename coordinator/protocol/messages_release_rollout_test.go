package protocol

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestReleaseRolloutWireFieldsAndWarmIntentPreservation(t *testing.T) {
	state := UpdateLifecycleModelReloading
	register := RegisterMessage{
		Type: TypeRegister, UpdateLifecycleState: &state,
		WarmIntent: &WarmIntent{
			ModelID: "model", ModelHash: "hash", SlotID: "slot",
			KVBackend: "paged", KVQuantization: "q8", MTPModelID: "mtp",
			DesiredGeneration: 91,
		},
	}
	encoded, err := json.Marshal(register)
	if err != nil {
		t.Fatal(err)
	}
	var decoded RegisterMessage
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.UpdateLifecycleState == nil || *decoded.UpdateLifecycleState != state ||
		!reflect.DeepEqual(decoded.WarmIntent, register.WarmIntent) {
		t.Fatalf("round trip mismatch: %s", encoded)
	}

	legacy, err := json.Marshal(RegisterMessage{Type: TypeRegister})
	if err != nil {
		t.Fatal(err)
	}
	var object map[string]any
	if err := json.Unmarshal(legacy, &object); err != nil {
		t.Fatal(err)
	}
	if _, ok := object["update_lifecycle_state"]; ok {
		t.Fatalf("legacy payload gained lifecycle field: %s", legacy)
	}
	if _, ok := object["warm_intent"]; ok {
		t.Fatalf("legacy payload gained warm intent: %s", legacy)
	}
}

func TestReleaseUpdateMessageExactShape(t *testing.T) {
	message := ReleaseUpdateMessage{
		Type: TypeReleaseUpdate, Version: "1.2.3", Platform: "macos-arm64",
		Backend: "mlx-swift", BinaryHash: "binary", BundleHash: "bundle",
		MetallibHash: "metallib", URL: "https://example.invalid/release",
		DesiredGeneration: 7,
	}
	encoded, err := json.Marshal(message)
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]any
	if err := json.Unmarshal(encoded, &fields); err != nil {
		t.Fatal(err)
	}
	want := []string{"type", "version", "platform", "backend", "binary_hash", "bundle_hash", "metallib_hash", "url", "desired_generation"}
	if len(fields) != len(want) {
		t.Fatalf("unexpected command shape: %s", encoded)
	}
	for _, field := range want {
		if _, ok := fields[field]; !ok {
			t.Fatalf("missing %s: %s", field, encoded)
		}
	}
}
