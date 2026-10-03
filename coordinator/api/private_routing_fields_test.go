package api

import (
	"testing"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
)

func TestStripProviderRoutingFieldsRemovesPrivateIdentity(t *testing.T) {
	parsed := map[string]any{
		"model":            "test-model",
		"provider_serial":  "PRIVATE-SERIAL-A",
		"provider_serials": []any{"PRIVATE-SERIAL-B"},
	}

	if !inreq.StripProviderRoutingFields(parsed) {
		t.Fatal("stripProviderRoutingFields returned false")
	}
	if _, ok := parsed["provider_serial"]; ok {
		t.Fatal("provider_serial was not stripped")
	}
	if _, ok := parsed["provider_serials"]; ok {
		t.Fatal("provider_serials was not stripped")
	}
	if parsed["model"] != "test-model" {
		t.Fatalf("unrelated request fields changed: %v", parsed)
	}
}
