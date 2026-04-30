package api

import (
	"reflect"
	"testing"
)

func TestParseProviderSerialAllowlist(t *testing.T) {
	parsed := map[string]any{
		"provider_serial": " SERIAL-A ",
		"provider_serials": []any{
			"SERIAL-B",
			"SERIAL-A",
			"",
			" SERIAL-C ",
		},
	}

	got, provided, err := parseProviderSerialAllowlist(parsed)
	if err != nil {
		t.Fatalf("parseProviderSerialAllowlist: %v", err)
	}
	if !provided {
		t.Fatal("provided=false, want true")
	}
	want := []string{"SERIAL-A", "SERIAL-B", "SERIAL-C"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("allowlist=%v, want %v", got, want)
	}

	if !stripProviderRoutingFields(parsed) {
		t.Fatal("stripProviderRoutingFields returned false")
	}
	if _, ok := parsed["provider_serial"]; ok {
		t.Fatal("provider_serial was not stripped")
	}
	if _, ok := parsed["provider_serials"]; ok {
		t.Fatal("provider_serials was not stripped")
	}
}

func TestParseProviderSerialAllowlistRejectsInvalidValues(t *testing.T) {
	tests := []map[string]any{
		{"provider_serials": []any{}},
		{"provider_serials": []any{" "}},
		{"provider_serials": []any{"SERIAL-A", 42}},
		{"provider_serials": 42},
	}
	for _, tc := range tests {
		if _, _, err := parseProviderSerialAllowlist(tc); err == nil {
			t.Fatalf("parseProviderSerialAllowlist(%v) returned nil error", tc)
		}
	}
}
