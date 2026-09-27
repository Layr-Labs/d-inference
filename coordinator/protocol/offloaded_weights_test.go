package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestOffloadedWeightsWireIsAdditive(t *testing.T) {
	var legacy ModelInfo
	if err := json.Unmarshal([]byte(`{"id":"legacy","estimated_memory_gb":12.5}`), &legacy); err != nil {
		t.Fatal(err)
	}
	if legacy.SSDOffloadedWeightBytes != 0 || legacy.NativeLoadTransientBytes != 0 || legacy.EstimatedMemoryGB != 12.5 {
		t.Fatal("legacy decode changed")
	}
	data, err := json.Marshal(legacy)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "ssd_offloaded_weight_bytes") {
		t.Fatal("empty offload field must be omitted")
	}
	if strings.Contains(string(data), "native_load_transient_bytes") {
		t.Fatal("empty native load allowance must be omitted")
	}
	legacy.SSDOffloadedWeightBytes = 32000153600
	legacy.NativeLoadTransientBytes = 6264197720
	data, err = json.Marshal(legacy)
	if err != nil {
		t.Fatal(err)
	}
	var decoded ModelInfo
	if err = json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.SSDOffloadedWeightBytes != legacy.SSDOffloadedWeightBytes {
		t.Fatal("offload bytes did not round trip")
	}
	if decoded.NativeLoadTransientBytes != legacy.NativeLoadTransientBytes {
		t.Fatal("native load allowance did not round trip")
	}
}
