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

func TestMiMoFullLoadSupplementWireDoesNotDeclareSSDOffload(t *testing.T) {
	info := ModelInfo{ID: "test-mimo-native-load", ModelType: "mimo_v2", SizeBytes: 172847269645,
		EstimatedMemoryGB:        float64(189354468528) / float64(uint64(1)<<30),
		NativeLoadTransientBytes: 16507198883}
	data, err := json.Marshal(info)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "ssd_offloaded_weight_bytes") {
		t.Fatal("MiMo unexpectedly declares SSD discount")
	}
	var decoded ModelInfo
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.SizeBytes != info.SizeBytes || decoded.NativeLoadTransientBytes != info.NativeLoadTransientBytes ||
		decoded.EstimatedMemoryGB != info.EstimatedMemoryGB || decoded.ModelType != "mimo_v2" {
		t.Fatal("full native byte/GiB units did not round trip")
	}
	for _, raw := range []string{
		`{"id":"mimo","native_load_transient_bytes":true}`,
		`{"id":"mimo","native_load_transient_bytes":1.5}`,
		`{"id":"mimo","native_load_transient_bytes":9223372036854775808}`,
	} {
		if err := json.Unmarshal([]byte(raw), &decoded); err == nil {
			t.Fatalf("malformed native byte count decoded: %s", raw)
		}
	}
}
