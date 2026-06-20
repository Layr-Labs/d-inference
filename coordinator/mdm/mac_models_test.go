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
		{"Mac16,9", 128, true},       // M4 Max Studio
		{"Mac15,14", 512, true},      // M3 Ultra Studio
		{"Mac17,2", 32, true},        // 14" M5 MacBook Pro
		{"Mac17,3", 32, true},        // 13" M5 MacBook Air
		{"Mac17,4", 32, true},        // 15" M5 MacBook Air
		{"Mac17,9", 64, true},        // 14" M5 Pro MacBook Pro
		{"Mac17,8", 64, true},        // 16" M5 Pro MacBook Pro
		{"Mac17,7", 128, true},       // 14" M5 Max MacBook Pro
		{"Mac17,6", 128, true},       // 16" M5 Max MacBook Pro
		{"Mac17,5", 8, true},         // MacBook Neo (A18 Pro), below reward floor
		{"Mac13,2", 128, true},       // M1 Ultra Studio
		{"Mac14,13", 96, true},       // M2 Max Studio
		{"Mac14,14", 192, true},      // M2 Ultra Studio
		{"NotAModel99,9", 0, false},  // unknown → ineligible for base rewards
		{"", 0, false},               // empty → no cap
	}
	for _, c := range cases {
		got, known := ModelMaxMemoryGB(c.model)
		if got != c.want || known != c.known {
			t.Errorf("ModelMaxMemoryGB(%q) = (%d, %v), want (%d, %v)", c.model, got, known, c.want, c.known)
		}
	}
}
