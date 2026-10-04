package request_test

import (
	"testing"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
)

func TestGenericResponseMetadataPreservesCallerEndpoint(t *testing.T) {
	endpoint, stops := inreq.GenericResponseMetadata(inreq.MessagesEndpoint, map[string]any{
		"stop_sequences": []any{"<END>"},
	})
	if endpoint != inreq.MessagesEndpoint {
		t.Fatalf("endpoint = %q, want %q", endpoint, inreq.MessagesEndpoint)
	}
	if len(stops) != 1 || stops[0] != "<END>" {
		t.Fatalf("stop sequences = %v, want [<END>]", stops)
	}

	endpoint, stops = inreq.GenericResponseMetadata(inreq.CompletionsEndpoint, map[string]any{})
	if endpoint != inreq.CompletionsEndpoint || stops != nil {
		t.Fatalf("completions metadata = (%q, %v)", endpoint, stops)
	}
}
