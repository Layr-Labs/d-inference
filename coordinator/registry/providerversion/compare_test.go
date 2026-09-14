package providerversion

import "testing"

func TestCompareVersions(t *testing.T) {
	var policy Policy
	tests := []struct {
		a, b string
		want int
	}{
		{"0.6.3", "0.6.3", 0},
		{"0.6.2", "0.6.3", -1},
		{"0.6.4", "0.6.3", 1},
		// Numeric compare, not lexicographic: "10" > "3".
		{"0.6.10", "0.6.3", 1},
		{"0.6.3", "0.6.10", -1},
		// "v"/"V" prefix tolerated.
		{"v0.6.3", "0.6.3", 0},
		{"V0.6.4", "v0.6.3", 1},
		// Different segment counts: missing segments compare as 0.
		{"0.6", "0.6.0", 0},
		{"0.6", "0.6.1", -1},
		{"1", "0.9.9", 1},
		{"0.7", "0.6.99", 1},
		// Empty parses as all-zeros: below any real floor.
		{"", "0.6.3", -1},
		{"", "", 0},
		// Unparseable segments compare as 0.
		{"garbage", "0.6.3", -1},
		{"garbage", "", 0},
		{"0.garbage.3", "0.0.3", 0},
		// A suffixed segment ("3-rc1") is unparseable → 0, so it sorts below
		// the plain release (fail-closed for tool routing).
		{"0.6.3-rc1", "0.6.3", -1},
		// Negative segments clamp to 0.
		{"0.-6.3", "0.0.3", 0},
		// Whitespace tolerated.
		{" 0.6.3 ", "0.6.3", 0},
	}
	for _, tc := range tests {
		if got := policy.Compare(tc.a, tc.b); got != tc.want {
			t.Errorf("CompareVersions(%q, %q) = %d, want %d", tc.a, tc.b, got, tc.want)
		}
		// Antisymmetry: swapping operands must negate the result.
		if got := policy.Compare(tc.b, tc.a); got != -tc.want {
			t.Errorf("CompareVersions(%q, %q) = %d, want %d", tc.b, tc.a, got, -tc.want)
		}
	}
}
