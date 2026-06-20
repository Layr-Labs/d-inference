package mdm

import "testing"

func TestModelMaxMemoryGB(t *testing.T) {
	cases := []struct {
		model string
		want  int
		known bool
	}{
		{"MacBookAir10,1", 16, true}, // M1 Air
		{"Mac15,8", 128, true},       // M3 Max 14"
		{"Mac16,9", 128, true},       // Mac Studio (ambiguous M4 Max/M3 Ultra) — conservative cap
		{"Mac13,2", 128, true},       // M1 Ultra Studio
		{"Mac14,13", 192, true},      // M2 Ultra Studio
		{"NotAModel99,9", 0, false},  // unknown → no cap
		{"", 0, false},               // empty → no cap
	}
	for _, c := range cases {
		got, known := ModelMaxMemoryGB(c.model)
		if got != c.want || known != c.known {
			t.Errorf("ModelMaxMemoryGB(%q) = (%d, %v), want (%d, %v)", c.model, got, known, c.want, c.known)
		}
	}
}
