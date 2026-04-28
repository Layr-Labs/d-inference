package api

import (
	"net/http/httptest"
	"reflect"
	"testing"
)

func TestParseProviderSerialAllowlist(t *testing.T) {
	parsed := map[string]any{
		"routing_preference": "cost",
		"provider_serial":    " SERIAL-A ",
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
	if _, ok := parsed["routing_preference"]; ok {
		t.Fatal("routing_preference was not stripped")
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

func TestParseRoutingPreference(t *testing.T) {
	tests := []struct {
		name   string
		target string
		header string
		body   map[string]any
		want   string
	}{
		{name: "default", target: "/v1/chat/completions", body: map[string]any{}, want: "performance"},
		{name: "query perf", target: "/v1/chat/completions?routing_preference=perf", body: map[string]any{"routing_preference": "cost"}, want: "performance"},
		{name: "header cost", target: "/v1/chat/completions", header: "cost", body: map[string]any{}, want: "cost"},
		{name: "body cost", target: "/v1/chat/completions", body: map[string]any{"routing_preference": "cost"}, want: "cost"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest("POST", tc.target, nil)
			if tc.header != "" {
				req.Header.Set("X-Darkbloom-Routing-Preference", tc.header)
			}
			got, err := parseRoutingPreference(req, tc.body)
			if err != nil {
				t.Fatalf("parseRoutingPreference: %v", err)
			}
			if got != tc.want {
				t.Fatalf("routing preference = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestParseRoutingPreferenceRejectsInvalidValues(t *testing.T) {
	req := httptest.NewRequest("POST", "/v1/chat/completions", nil)
	if _, err := parseRoutingPreference(req, map[string]any{"routing_preference": 42}); err == nil {
		t.Fatal("expected non-string body value to fail")
	}
	req = httptest.NewRequest("POST", "/v1/chat/completions?routing_preference=cheap", nil)
	if _, err := parseRoutingPreference(req, map[string]any{}); err == nil {
		t.Fatal("expected unknown query value to fail")
	}
}
