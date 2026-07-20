package protocol

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestRegisterToolConstraintCapabilityIsAdditive(t *testing.T) {
	legacy, err := json.Marshal(RegisterMessage{Type: TypeRegister})
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(legacy, []byte("tool_constraint")) {
		t.Fatalf("legacy registration emitted constraint fields: %s", legacy)
	}

	current, err := json.Marshal(RegisterMessage{
		Type:                   TypeRegister,
		ToolConstraintProtocol: 1,
		ToolConstraintModels:   []string{"gemma-4-build"},
	})
	if err != nil {
		t.Fatal(err)
	}
	var decoded RegisterMessage
	if err := json.Unmarshal(current, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.ToolConstraintProtocol != 1 ||
		len(decoded.ToolConstraintModels) != 1 ||
		decoded.ToolConstraintModels[0] != "gemma-4-build" {
		t.Fatalf("capability round trip failed: %+v", decoded)
	}
}

func TestModelsUpdateToolConstraintCapabilityIsAdditive(t *testing.T) {
	legacy, err := json.Marshal(ModelsUpdateMessage{
		Type:   TypeModelsUpdate,
		Models: []ModelInfo{{ID: "m"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(legacy, []byte("tool_constraint")) {
		t.Fatalf("legacy models_update emitted constraint fields: %s", legacy)
	}

	current, err := json.Marshal(ModelsUpdateMessage{
		Type:                   TypeModelsUpdate,
		Models:                 []ModelInfo{{ID: "gemma-4-hot"}},
		ToolConstraintProtocol: 1,
		ToolConstraintModels:   []string{"gemma-4-hot"},
	})
	if err != nil {
		t.Fatal(err)
	}
	var decoded ModelsUpdateMessage
	if err := json.Unmarshal(current, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.ToolConstraintProtocol != 1 ||
		len(decoded.ToolConstraintModels) != 1 ||
		decoded.ToolConstraintModels[0] != "gemma-4-hot" {
		t.Fatalf("models_update capability round trip failed: %+v", decoded)
	}
}
