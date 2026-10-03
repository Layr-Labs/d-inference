package api

import (
	"encoding/json"
	"math/rand/v2"
	"strings"
	"testing"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
)

// jsonLenSpecialStrings are the string shapes whose encoded length differs
// from their byte length: every short escape, every other control byte, the
// HTML-significant bytes, DEL (safe), invalid UTF-8 (per-byte �),
// U+2028/U+2029 (escaped unconditionally), a genuine U+FFFD (kept raw), and
// multi-byte runes.
var jsonLenSpecialStrings = []string{
	"",
	"plain ascii",
	"quote\" backslash\\ ",
	"\b\f\n\r\t",
	"\x00\x01\x1f",
	"<tag> & amp",
	"\x7f del is safe",
	"bad utf8 \xff\xfe end",
	"truncated rune \xe2\x82",
	"line\u2028sep\u2029par",
	"replacement \uFFFD kept",
	"émoji 🎉 日本語",
	strings.Repeat("a\"b<c>&\n", 50),
}

// TestJSONValueLenMatchesMarshal is the property test: random decoder-shaped
// trees seeded with the special strings must measure exactly like the encoder,
// and the wrapper must agree with marshal-and-measure for everything else.
func TestJSONValueLenMatchesMarshal(t *testing.T) {
	rnd := rand.New(rand.NewPCG(3, 9))
	var gen func(depth int) any
	gen = func(depth int) any {
		switch k := rnd.IntN(8); {
		case k == 0:
			return nil
		case k == 1:
			return rnd.IntN(2) == 0
		case k == 2:
			return json.Number([]string{"0", "-1", "3.25", "1e10", "9007199254740993"}[rnd.IntN(5)])
		case k <= 4 || depth > 3:
			return jsonLenSpecialStrings[rnd.IntN(len(jsonLenSpecialStrings))]
		case k == 5:
			m := make(map[string]any)
			for i := rnd.IntN(4); i > 0; i-- {
				m[jsonLenSpecialStrings[rnd.IntN(len(jsonLenSpecialStrings))]+string(rune('a'+i))] = gen(depth + 1)
			}
			return m
		default:
			arr := make([]any, rnd.IntN(4))
			for i := range arr {
				arr[i] = gen(depth + 1)
			}
			return arr
		}
	}
	for i := 0; i < 2000; i++ {
		v := gen(0)
		want, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		if got := inreq.JsonValueLen(v); got != len(want) {
			t.Fatalf("tree %d: len = %d, want %d for %s", i, got, len(want), want)
		}
	}
	// Fallback path: values the counter declines still measure exactly, and an
	// unencodable value reports 0 like the marshal-and-measure path.
	if got := inreq.JsonValueLen(map[string]any{"n": 42, "f": 0.5}); got != len(`{"f":0.5,"n":42}`) {
		t.Fatalf("fallback len = %d", got)
	}
	if got := inreq.JsonValueLen(map[string]any{"bad": json.Number("nope")}); got != 0 {
		t.Fatalf("unencodable value len = %d, want 0", got)
	}
}

func TestJSONNumberLiteralValid(t *testing.T) {
	valid := []string{"0", "-0", "1", "-12", "1.5", "0.25", "1e5", "1E+5", "2.5e-3", "9007199254740993"}
	invalid := []string{"", "-", "+1", "01", "1.", ".5", "1e", "1e+", "0x10", "nope", "1 ", "--1"}
	for _, s := range valid {
		if !inreq.JsonNumberLiteralValid(s) {
			t.Errorf("%q rejected", s)
		}
		if _, err := json.Marshal(json.Number(s)); err != nil {
			t.Errorf("%q: encoder disagrees: %v", s, err)
		}
	}
	for _, s := range invalid {
		if inreq.JsonNumberLiteralValid(s) {
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
