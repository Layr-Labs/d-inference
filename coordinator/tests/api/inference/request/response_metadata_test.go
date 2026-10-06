package request_test

import (
	"encoding/json"
	"net/http/httptest"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api/inference/request"
)

func TestTruthyRequestFlag(t *testing.T) {
	t.Parallel()
	cases := []struct {
		in   any
		want bool
	}{
		{true, true},
		{false, false},
		{"true", true},
		{"TRUE", true},
		{"1", true},
		{"yes", true},
		{"false", false},
		{"", false},
		{float64(1), true},
		{float64(0), false},
		{json.Number("1"), true},
		{json.Number("0"), false},
		{nil, false},
	}
	for _, tc := range cases {
		r := httptest.NewRequest("POST", "/v1/chat/completions", nil)
		production.ApplyMetadataDetailsRequest(r, map[string]any{"metadata_details": tc.in})
		if got := r.Header.Get(production.MetadataDetailsHeader) == "true"; got != tc.want {
			t.Errorf("truthyRequestFlag(%#v) = %v, want %v", tc.in, got, tc.want)
		}
	}
}
