package registry_test

import (
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestParseTTFTAdmissionMode(t *testing.T) {
	cases := map[string]production.TTFTAdmissionMode{
		"":        production.TTFTAdmissionOff,
		"off":     production.TTFTAdmissionOff,
		"garbage": production.TTFTAdmissionOff,
		"shadow":  production.TTFTAdmissionShadow,
		" SHADOW": production.TTFTAdmissionShadow,
		"enforce": production.TTFTAdmissionEnforce,
	}
	for in, want := range cases {
		if got := production.ParseTTFTAdmissionMode(in); got != want {
			t.Errorf("ParseTTFTAdmissionMode(%q) = %v, want %v", in, got, want)
		}
	}
}
