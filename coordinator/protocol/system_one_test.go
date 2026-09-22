package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestModelInfoSystemOneCapabilityIsExplicit(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		data, err := json.Marshal(ModelInfo{ID: "laya", ModelType: "laya", SystemOne: enabled})
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(data), `"system_one":true`) != enabled {
			t.Fatalf("capability wire encoding %s", data)
		}
		var decoded ModelInfo
		if err := json.Unmarshal(data, &decoded); err != nil || decoded.SystemOne != enabled {
			t.Fatalf("capability round trip %+v %v", decoded, err)
		}
	}
	var legacy ModelInfo
	if err := json.Unmarshal([]byte(`{"id":"laya","model_type":"laya"}`), &legacy); err != nil || legacy.SystemOne {
		t.Fatalf("legacy gained native capability: %+v %v", legacy, err)
	}
}
