package promptcontract

import (
	"bytes"
	"encoding/json"
	"errors"
	"testing"
)

func TestResponsesInferencePreservesOrderedInlineMediaAndHistory(t *testing.T) {
	body := []byte(`{"model":"native-vision","max_output_tokens":64,"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"First"},{"type":"input_image","image_url":"data:image/png;base64,AAAA","detail":"auto"},{"type":"input_text","text":"then"},{"type":"video_url","video_url":{"url":"data:video/mp4;base64,BBBB"}},{"type":"input_image","image_url":"data:image/png;base64,CCCC"}]},{"type":"function_call","call_id":"actual-a","name":"describe","arguments":"{\"literal\":\"<think>\\n\"}"},{"type":"function_call_output","call_id":"actual-a","output":"received"},{"role":"user","content":"Keep the ordering."}]}`)
	want := []byte(`{"model":"native-vision","max_tokens":64,"messages":[{"role":"user","content":[{"type":"text","text":"First"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA","detail":"auto"}},{"type":"text","text":"then"},{"type":"video_url","video_url":{"url":"data:video/mp4;base64,BBBB"}},{"type":"image_url","image_url":{"url":"data:image/png;base64,CCCC"}}]},{"role":"assistant","content":"","tool_calls":[{"id":"actual-a","type":"function","function":{"name":"describe","arguments":"{\"literal\":\"<think>\\n\"}"}}]},{"role":"tool","tool_call_id":"actual-a","content":"received"},{"role":"user","content":"Keep the ordering."}]}`)
	got, err := LowerResponsesInferenceBody(body)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(canonicalJSON(t, got), canonicalJSON(t, want)) {
		t.Fatalf("media/history changed\ngot: %s\nwant: %s", got, want)
	}
	if _, err := LowerProviderBody(EndpointResponses, body); !errors.Is(err, ErrEndpointBodyUnsupported) {
		t.Fatal("media became eligible for text-only cache planning")
	}
}

func TestResponsesInferencePreservesInlineToolOutputMedia(t *testing.T) {
	body := []byte(`{"input":[{"type":"function_call_output","call_id":"actual","output":[{"type":"input_text","text":"Result"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA","detail":"low"}}]}]}`)
	got, err := LowerResponsesInferenceBody(body)
	if err != nil {
		t.Fatal(err)
	}
	want := []byte(`{"messages":[{"role":"tool","tool_call_id":"actual","content":[{"type":"text","text":"Result"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA","detail":"low"}}]}]}`)
	if !bytes.Equal(canonicalJSON(t, got), canonicalJSON(t, want)) {
		t.Fatal("tool output media lost")
	}
	if _, err := LowerProviderBody(EndpointResponses, body); !errors.Is(err, ErrEndpointBodyUnsupported) {
		t.Fatal("tool-output media became eligible for text-only cache planning")
	}
}

func TestResponsesInferenceRejectsMalformedMediaContainers(t *testing.T) {
	for _, key := range []string{"content", "output"} {
		body := []byte(`{"input":[{"type":"function_call_output","call_id":"actual","` + key + `":{"type":"input_image","image_url":"data:image/png;base64,AAAA"}}]}`)
		if key == "content" {
			body = []byte(`{"input":[{"role":"user","content":{"type":"input_image","image_url":"data:image/png;base64,AAAA"}}]}`)
		}
		if _, err := LowerResponsesInferenceBody(body); err == nil {
			t.Fatal("malformed media converted into ordinary text")
		}
	}
}

func TestResponsesInferenceRefusesUnsupportedOrNonInlineParts(t *testing.T) {
	parts := []string{
		`{"type":"input_image","image_url":"https://example.invalid/image.png"}`,
		`{"type":"image_url","image_url":{"url":"file:///private/image.png"}}`,
		`{"type":"video_url","video_url":{"url":"http://127.0.0.1/video.mp4"}}`,
		`{"type":"input_image","image_url":"data:image/png;base64,AAAA","file_id":"file-1"}`,
		`{"type":"input_image","file_id":"file-1"}`,
		`{"type":"input_file","file_data":"data:application/pdf;base64,AAAA"}`,
		`{"type":"input_audio","data":"AAAA"}`,
		`{"type":"input_video","video_url":"data:video/mp4;base64,AAAA"}`,
		`{"type":"unknown","text":"must not silently become text"}`,
		`{"type":"input_image","image_url":42}`,
		`{"type":"image_url","image_url":{"url":""}}`,
	}
	for _, part := range parts {
		t.Run(part, func(t *testing.T) {
			body := []byte(`{"input":[{"role":"user","content":[` + part + `]}]}`)
			if _, err := LowerResponsesInferenceBody(body); err == nil {
				t.Fatal("unsupported content accepted or dropped")
			}
		})
	}
}

func TestResponsesInferenceTextRemainsCacheContractExact(t *testing.T) {
	for _, body := range []string{
		`{"input":"hello","temperature":0.75}`,
		`{"input":[{"role":"user","content":[{"type":"input_text","text":"a"},{"type":"output_text","text":"b"}]}]}`,
		`{"input":[{"role":"user","content":{"value":"<tag>&"}}]}`,
	} {
		got, err := LowerResponsesInferenceBody([]byte(body))
		if err != nil {
			t.Fatal(err)
		}
		want, err := LowerProviderBody(EndpointResponses, []byte(body))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(got, want) {
			t.Fatal("text-only lowering differs from frozen cache contract")
		}
		if !json.Valid(got) {
			t.Fatal("invalid JSON")
		}
	}
}
