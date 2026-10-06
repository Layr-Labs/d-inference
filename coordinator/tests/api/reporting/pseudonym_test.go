package reporting_test

import (
	"encoding/binary"
	"regexp"
	"strings"
	"testing"

	pseudonym "github.com/eigeninference/d-inference/coordinator/internal/api/reporting/pseudonym"
)

var pseudonymPattern = regexp.MustCompile(`^[a-z0-9]+-[a-z0-9]+-\d{4}$`)

func TestPseudonymStable(t *testing.T) {
	id := "5ada837c-c689-4c67-ae60-699c1eb96495"
	a := pseudonym.Generate(id)
	b := pseudonym.Generate(id)
	if a != b {
		t.Fatalf("pseudonym not stable: %q vs %q", a, b)
	}
}

func TestPseudonymFormat(t *testing.T) {
	cases := []string{
		"5ada837c-c689-4c67-ae60-699c1eb96495",
		"00000000-0000-0000-0000-000000000000",
		"ffffffff-ffff-ffff-ffff-ffffffffffff",
		"single-string",
	}
	for _, id := range cases {
		got := pseudonym.Generate(id)
		if !pseudonymPattern.MatchString(got) {
			t.Errorf("pseudonym(%q) = %q, want adjective-animal-NNNN", id, got)
		}
	}
}

func TestPseudonymEmpty(t *testing.T) {
	if got := pseudonym.Generate(""); got != "anon" {
		t.Errorf("pseudonym(\"\") = %q, want \"anon\"", got)
	}
}

func TestPseudonymDistinct(t *testing.T) {
	a := pseudonym.Generate("acct-1")
	b := pseudonym.Generate("acct-2")
	if a == b {
		t.Fatalf("different inputs gave same pseudonym: %q", a)
	}
}

func TestPseudonymTablesNoBlanks(t *testing.T) {
	// Exhaust the full index space used by both word selectors, without
	// exposing or mutating the vocabulary tables.
	for i := 0; i <= 65535; i++ {
		var digest [32]byte
		binary.BigEndian.PutUint16(digest[0:2], uint16(i))
		binary.BigEndian.PutUint16(digest[2:4], uint16(i))
		words := strings.Split(pseudonym.FromDigest(digest), "-")
		if words[0] == "" {
			t.Errorf("pseudonymAdjectives[%d] is empty", i)
		}
		if words[1] == "" {
			t.Errorf("pseudonymAnimals[%d] is empty", i)
		}
	}
}
