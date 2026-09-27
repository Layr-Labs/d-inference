package receipts

import (
	"bytes"
	"strings"
	"testing"
)

func TestCanonicalJSONOrderingWhitespaceAndEscapes(t *testing.T) {
	raw := []byte(` { "z": "<tag>", "a":"\u0061", "slash":"x\/y", "line":"one\ntwo" } `)
	got, err := CanonicalJSON(raw)
	if err != nil {
		t.Fatalf("CanonicalJSON: %v", err)
	}
	const want = `{"a":"a","line":"one\ntwo","slash":"x/y","z":"\u003ctag\u003e"}`
	if string(got) != want {
		t.Fatalf("CanonicalJSON() = %s, want %s", got, want)
	}
	hash, err := HashCanonicalJSON(raw)
	if err != nil {
		t.Fatalf("HashCanonicalJSON: %v", err)
	}
	if hash != HashBytes([]byte(want)) {
		t.Fatalf("HashCanonicalJSON() = %q, want hash of %q", hash, want)
	}
}

func TestCanonicalJSONNestedObjectsAndArrays(t *testing.T) {
	raw := []byte(`{"items":[{"z":1,"a":2},"{\"x\":1,\"x\":2}",{"nested":{"b":true,"a":false}}]}`)
	got, err := CanonicalJSON(raw)
	if err != nil {
		t.Fatalf("CanonicalJSON: %v", err)
	}
	const want = `{"items":[{"a":2,"z":1},"{\"x\":1,\"x\":2}",{"nested":{"a":false,"b":true}}]}`
	if string(got) != want {
		t.Fatalf("CanonicalJSON() = %s, want %s", got, want)
	}
}

func TestCanonicalJSONRejectsDuplicateKeys(t *testing.T) {
	for name, raw := range map[string]string{
		"root duplicate":            `{"x":1,"x":2}`,
		"nested duplicate":          `{"outer":{"x":1,"x":2}}`,
		"object in array duplicate": `{"items":[{"x":1,"x":2}]}`,
		"escaped equivalent keys":   `{"a":1,"\u0061":2}`,
		"nested escaped keys":       `{"outer":{"a":1,"\u0061":2}}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := CanonicalJSON([]byte(raw)); err == nil {
				t.Fatalf("CanonicalJSON accepted duplicate keys in %s", raw)
			}
		})
	}
}

func TestCanonicalJSONPreservesNumberLexemes(t *testing.T) {
	raw := []byte(`{"precise":9007199254740993,"decimal":1.2300,"exponent":1e+09,"negative_zero":-0}`)
	got, err := CanonicalJSON(raw)
	if err != nil {
		t.Fatalf("CanonicalJSON: %v", err)
	}
	const want = `{"decimal":1.2300,"exponent":1e+09,"negative_zero":-0,"precise":9007199254740993}`
	if string(got) != want {
		t.Fatalf("CanonicalJSON() = %s, want %s", got, want)
	}
}

func TestCanonicalJSONRejectsInvalidTrailingAndNonObjectInput(t *testing.T) {
	for name, raw := range map[string]string{
		"invalid syntax":        `{"x":}`,
		"trailing object":       `{} {}`,
		"trailing scalar":       `{} true`,
		"trailing invalid":      `{} x`,
		"top level array":       `[]`,
		"top level scalar":      `1`,
		"top level null":        `null`,
		"empty input":           ``,
		"whitespace only input": " \t\n",
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := CanonicalJSON([]byte(raw)); err == nil {
				t.Fatalf("CanonicalJSON accepted %q", raw)
			}
		})
	}
}

func TestCanonicalJSONDepthLimit(t *testing.T) {
	const maxDepth = 256
	withinLimit := `{"x":` + strings.Repeat("[", maxDepth-1) + "0" + strings.Repeat("]", maxDepth-1) + "}"
	if _, err := CanonicalJSON([]byte(withinLimit)); err != nil {
		t.Fatalf("CanonicalJSON rejected depth %d: %v", maxDepth, err)
	}
	overLimit := `{"x":` + strings.Repeat("[", maxDepth) + "0" + strings.Repeat("]", maxDepth) + "}"
	if _, err := CanonicalJSON([]byte(overLimit)); err == nil {
		t.Fatalf("CanonicalJSON accepted depth greater than %d", maxDepth)
	}
}

func TestCanonicalJSONRawSizeLimit(t *testing.T) {
	const maxBytes = 16 << 20
	prefix := []byte(`{"x":"`)
	suffix := []byte(`"}`)
	withinLimit := make([]byte, 0, maxBytes)
	withinLimit = append(withinLimit, prefix...)
	withinLimit = append(withinLimit, bytes.Repeat([]byte{'a'}, maxBytes-len(prefix)-len(suffix))...)
	withinLimit = append(withinLimit, suffix...)
	if len(withinLimit) != maxBytes {
		t.Fatalf("test input size = %d, want %d", len(withinLimit), maxBytes)
	}
	if _, err := CanonicalJSON(withinLimit); err != nil {
		t.Fatalf("CanonicalJSON rejected input at %d bytes: %v", maxBytes, err)
	}
	overLimit := append(append([]byte(nil), withinLimit...), ' ')
	if _, err := CanonicalJSON(overLimit); err == nil {
		t.Fatalf("CanonicalJSON accepted input at %d bytes", len(overLimit))
	}
}
