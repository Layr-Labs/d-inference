package dispatch

import (
	"encoding/json"
	"testing"
)

func TestJSONNumberLiteralValid(t *testing.T) {
	valid := []string{"0", "-0", "1", "-12", "1.5", "0.25", "1e5", "1E+5", "2.5e-3", "9007199254740993"}
	invalid := []string{"", "-", "+1", "01", "1.", ".5", "1e", "1e+", "0x10", "nope", "1 ", "--1"}
	for _, s := range valid {
		if !JSONNumberLiteralValid(s) {
			t.Errorf("%q rejected", s)
		}
		if _, err := json.Marshal(json.Number(s)); err != nil {
			t.Errorf("%q: encoder disagrees: %v", s, err)
		}
	}
	for _, s := range invalid {
		if JSONNumberLiteralValid(s) {
			t.Errorf("%q accepted", s)
		}
		if s == "" {
			continue // the encoder substitutes "0" for the zero value
		}
		if _, err := json.Marshal(json.Number(s)); err == nil {
			t.Errorf("%q: encoder disagrees (accepted)", s)
		}
	}
}
