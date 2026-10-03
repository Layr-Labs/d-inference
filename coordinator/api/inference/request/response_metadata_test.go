package request

import (
	"encoding/json"
	"testing"
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
		if got := truthyRequestFlag(tc.in); got != tc.want {
			t.Errorf("truthyRequestFlag(%#v) = %v, want %v", tc.in, got, tc.want)
		}
	}
}
