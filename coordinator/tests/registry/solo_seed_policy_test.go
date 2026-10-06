package registry_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/quality"
)

func TestParseModelFloatMapSeedEntries(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want map[string]float64
	}{
		{"empty", "", nil},
		{"single", "gemma-4-26b-qat-4bit=14", map[string]float64{"gemma-4-26b-qat-4bit": 14}},
		{"multi_with_spaces", " gemma-4-26b-qat-4bit=14 , gpt-oss-20b=30 ", map[string]float64{"gemma-4-26b-qat-4bit": 14, "gpt-oss-20b": 30}},
		{"uppercase_key_lowered", "GPT-OSS-20B=30", map[string]float64{"gpt-oss-20b": 30}},
		{"bad_entries_skipped", "bogus,=3,x=,gemma=abc,gemma=0,gemma=-2,good=14.5", map[string]float64{"good": 14.5}},
		// NaN evades a naive <= 0 filter and must not reach admission math.
		{"non_finite_skipped", "a=NaN,b=+Inf,c=Inf,d=-Inf,e=Infinity,good=2", map[string]float64{"good": 2}},
		{"all_invalid", "bogus,=3,x=abc", nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := quality.ParseModelFloatMap(tc.raw)
			if len(got) != len(tc.want) {
				t.Fatalf("parseModelFloatMap(%q) = %v, want %v", tc.raw, got, tc.want)
			}
			for k, v := range tc.want {
				if got[k] != v {
					t.Fatalf("parseModelFloatMap(%q)[%q] = %v, want %v", tc.raw, k, got[k], v)
				}
			}
		})
	}
}

func TestSoloSeedFleetFallbacksParsing(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want map[string]float64
	}{
		{name: "no_class_entries_passthrough", raw: "a=20,b=30", want: map[string]float64{"a": 20, "b": 30}},
		{name: "clamped_to_slowest_class", raw: "a=70,a@m4|max=70,a@m1|pro=14", want: map[string]float64{"a": 14}},
		{name: "fleet_already_below_classes", raw: "a=9,a@m4|max=70", want: map[string]float64{"a": 9}},
		{name: "class_only_has_no_fleet_entry", raw: "a@m4|max=70", want: nil},
		{name: "clamp_is_per_model", raw: "a=70,b=70,a@m1|pro=14", want: map[string]float64{"a": 14, "b": 70}},
		{name: "empty", raw: "", want: nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := quality.SeedFleetFallbacks(quality.ParseModelFloatMap(tc.raw))
			if len(got) != len(tc.want) {
				t.Fatalf("soloSeedFleetFallbacks(%q) = %v, want %v", tc.raw, got, tc.want)
			}
			for k, v := range tc.want {
				if got[k] != v {
					t.Fatalf("soloSeedFleetFallbacks(%q)[%q] = %v, want %v", tc.raw, k, got[k], v)
				}
			}
		})
	}
}
