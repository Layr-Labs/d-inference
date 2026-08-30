package semverutil

import "testing"

func TestSemVerPrereleaseFinalAndBuildOrdering(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"2.0.1-rc.1", "2.0.1", -1},
		{"2.0.1", "2.0.1-rc.9", 1},
		{"2.0.1+build.7", "2.0.1+build.2", 0},
		{"2.0.1-rc.2", "2.0.1-rc.1", 1},
	}
	for _, test := range cases {
		got, ok := Compare(test.a, test.b)
		if !ok || (got < 0) != (test.want < 0) || (got > 0) != (test.want > 0) {
			t.Fatalf("Compare(%q,%q) = %d/%v, want sign %d", test.a, test.b, got, ok, test.want)
		}
	}
	if _, ok := Compare("2.0", "2.0.0"); ok {
		t.Fatal("non-strict SemVer was accepted")
	}
}
