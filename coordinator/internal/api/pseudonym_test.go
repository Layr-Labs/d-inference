package api

import (
	"regexp"
	"testing"
)

var pseudonymPattern = regexp.MustCompile(`^[a-z0-9]+-[a-z0-9]+-\d{4}$`)

func TestPseudonymStable(t *testing.T) {
	id := "5ada837c-c689-4c67-ae60-699c1eb96495"
	a := pseudonym(id)
	b := pseudonym(id)
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
		got := pseudonym(id)
		if !pseudonymPattern.MatchString(got) {
			t.Errorf("pseudonym(%q) = %q, want adjective-animal-NNNN", id, got)
		}
	}
}

func TestPseudonymEmpty(t *testing.T) {
	if got := pseudonym(""); got != "anon" {
		t.Errorf("pseudonym(\"\") = %q, want \"anon\"", got)
	}
}

func TestPseudonymDistinct(t *testing.T) {
	a := pseudonym("acct-1")
	b := pseudonym("acct-2")
	if a == b {
		t.Fatalf("different inputs gave same pseudonym: %q", a)
	}
}

func TestPseudonymTablesNoBlanks(t *testing.T) {
	for i, w := range pseudonymAdjectives {
		if w == "" {
			t.Errorf("pseudonymAdjectives[%d] is empty", i)
		}
	}
	for i, w := range pseudonymAnimals {
		if w == "" {
			t.Errorf("pseudonymAnimals[%d] is empty", i)
		}
	}
}
