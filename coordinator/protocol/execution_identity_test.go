package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestExecutionIdentityWireCompatibility(t *testing.T) {
	const identity = "kvq-v1:affine-v1-k4v4-g64-f32-h128-s1:prefill=direct"
	for _, value := range []any{ModelInfo{ID: "m"}, BackendSlotCapacity{Model: "m", State: "idle"}} {
		data, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(data), "execution_identity") {
			t.Fatal("legacy/native identity no longer omitted")
		}
	}
	data, err := json.Marshal(BackendSlotCapacity{Model: "m", State: "idle", ExecutionIdentity: identity})
	if err != nil {
		t.Fatal(err)
	}
	var slot BackendSlotCapacity
	if err = json.Unmarshal(data, &slot); err != nil || slot.ExecutionIdentity != identity {
		t.Fatalf("slot roundtrip %s: %v", data, err)
	}
	modelData, err := json.Marshal(ModelInfo{ID: "m", ExecutionIdentity: identity})
	if err != nil {
		t.Fatal(err)
	}
	var model ModelInfo
	if err = json.Unmarshal(modelData, &model); err != nil || model.ExecutionIdentity != identity {
		t.Fatalf("declared identity roundtrip %s: %v", modelData, err)
	}
}
