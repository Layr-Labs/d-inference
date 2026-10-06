package request_test

import (
	"testing"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
)

func TestNativeMediaToolsTraitsInspectOnlyToolResultMedia(t *testing.T) {
	for _, raw := range []string{
		`{"messages":[{"role":"tool","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]}]}`,
		`{"input":[{"type":"function_call_output","call_id":"actual","output":[{"type":"input_image","image_url":"data:image/png;base64,AAAA"}]}]}`,
	} {
		p, err := inreq.DecodeInferenceJSONObject([]byte(raw))
		if err != nil || !inreq.RequestHasMediaToolResults(p) {
			t.Fatal("tool media not recognized")
		}
	}
	for _, raw := range []string{
		`{"messages":[{"role":"user","content":[{"type":"image_url"}]}]}`,
		`{"messages":[{"role":"tool","content":"{\"type\":\"input_image\"}"}]}`,
		`{"tools":[{"function":{"parameters":{"type":"image_url"}}}],"metadata":{"role":"tool","content":[{"type":"image_url"}]}}`,
	} {
		p, err := inreq.DecodeInferenceJSONObject([]byte(raw))
		if err != nil || inreq.RequestHasMediaToolResults(p) {
			t.Fatal("non-media data acquired a capability requirement")
		}
	}
}
