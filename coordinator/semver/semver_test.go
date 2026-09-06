package semver

import "testing"

func TestParseCanonicalSemVer(t *testing.T) {
	t.Parallel()
	valid := []string{
		"0.0.0",
		"1.2.3-alpha+001",
		"1.0.0-alpha.1",
		"1.0.0-0.3.7",
		"1.0.0-x.7.z.92+build.01",
		"184467440737095516160.0.1",
		"1.0.0-184467440737095516160",
	}
	for _, raw := range valid {
		raw := raw
		t.Run(raw, func(t *testing.T) {
			t.Parallel()
			if _, err := Parse(raw); err != nil {
				t.Fatalf("Parse(%q): %v", raw, err)
			}
		})
	}
}

func TestParseRejectsNoncanonicalSemVer(t *testing.T) {
	t.Parallel()
	invalid := []string{
		"",
		"v1.0.0",
		"1.0",
		"01.0.0",
		"1.01.0",
		"1.0.01",
		"1.0.0-",
		"1.0.0-alpha..1",
		"1.0.0-alpha.01",
		"1.0.0+",
		"1.0.0+build+second",
		"1.0.0-alpha_beta",
		"1.0.0-β",
	}
	for _, raw := range invalid {
		raw := raw
		t.Run(raw, func(t *testing.T) {
			t.Parallel()
			if _, err := Parse(raw); err == nil {
				t.Fatalf("Parse(%q) unexpectedly succeeded", raw)
			}
		})
	}
}

func TestCompareSemVerPrecedence(t *testing.T) {
	t.Parallel()
	ordered := []string{
		"1.0.0-alpha",
		"1.0.0-alpha.1",
		"1.0.0-alpha.beta",
		"1.0.0-beta",
		"1.0.0-beta.2",
		"1.0.0-beta.11",
		"1.0.0-rc.1",
		"1.0.0",
		"2.0.0",
		"184467440737095516160.0.0",
		"184467440737095516161.0.0",
	}
	for index := 0; index < len(ordered)-1; index++ {
		left := ordered[index]
		right := ordered[index+1]
		comparison, err := Compare(left, right)
		if err != nil {
			t.Fatalf("Compare(%q, %q): %v", left, right, err)
		}
		if comparison >= 0 {
			t.Fatalf("Compare(%q, %q) = %d, want negative", left, right, comparison)
		}
		reverse, err := Compare(right, left)
		if err != nil {
			t.Fatalf("Compare(%q, %q): %v", right, left, err)
		}
		if reverse <= 0 {
			t.Fatalf("Compare(%q, %q) = %d, want positive", right, left, reverse)
		}
	}
}

func TestCompareIgnoresBuildMetadata(t *testing.T) {
	t.Parallel()
	comparison, err := Compare("1.0.0+build.1", "1.0.0+build.2")
	if err != nil {
		t.Fatal(err)
	}
	if comparison != 0 {
		t.Fatalf("comparison = %d, want 0", comparison)
	}
}

func TestCompareUsesASCIIIdentifierOrdering(t *testing.T) {
	t.Parallel()
	comparison, err := Compare("1.0.0-B", "1.0.0-a")
	if err != nil {
		t.Fatal(err)
	}
	if comparison >= 0 {
		t.Fatalf("comparison = %d, want negative", comparison)
	}
}
