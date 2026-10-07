package observation_test

import (
	"strings"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api/observation"
	metriclabels "github.com/eigeninference/d-inference/coordinator/internal/observation/labels"
)

func TestSanitizeVersionTag(t *testing.T) {
	cases := map[string]string{
		"":                       "unknown",
		"  ":                     "unknown",
		"0.6.20":                 "0.6.x",
		"v0.8.16":                "0.8.x",
		"0.8.16-rc.1":            "prerelease",
		"0.8.16-beta.2":          "prerelease",
		"build-a1":               "other",
		"0.8.16-abc123":          "other",
		"0.8.16-rc":              "other",
		"0.8.16+build.5":         "other",
		"1.2":                    "other",
		"1.2.3.4":                "other",
		"01.2.3":                 "other",
		"0.6.20 evil:tag":        "other",
		"0.6,20":                 "other",
		strings.Repeat("9", 40):  "other",
		strings.Repeat("a", 200): "other",
	}
	for in, want := range cases {
		if got := metriclabels.Version(in); got != want {
			t.Errorf("sanitizeVersionTag(%q) = %q, want %q", in, got, want)
		}
	}
	if got := production.ProviderVersionTag(nil); got != "unknown" {
		t.Errorf("providerVersionTag(nil) = %q, want unknown", got)
	}
}
