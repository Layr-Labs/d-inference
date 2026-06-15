package registry

import "testing"

func TestEstimateMachineWatts(t *testing.T) {
	tests := []struct {
		name       string
		chipFamily string
		chipTier   string
		gpuCores   int
		want       float64
	}{
		// Table hits across families/tiers.
		{"M1 Base", "M1", "Base", 8, 40},
		{"M1 Max", "M1", "Max", 32, 115},
		{"M1 Ultra", "M1", "Ultra", 48, 215},
		{"M2 Ultra", "M2", "Ultra", 60, 280},
		{"M3 Max", "M3", "Max", 40, 150},
		{"M4 Base", "M4", "Base", 10, 65},
		{"M4 Pro", "M4", "Pro", 20, 100},
		{"M4 Max", "M4", "Max", 40, 170},
		{"M5 Ultra", "M5", "Ultra", 80, 310},

		// Case-insensitivity on family and tier.
		{"lowercase family + tier", "m4", "max", 40, 170},
		{"MAX tier upper", "M1", "MAX", 32, 115},
		{"Max tier title", "M1", "Max", 32, 115},
		{"mixed family", "m2", "PrO", 19, 75},

		// Empty / whitespace tier normalizes to Base.
		{"empty tier -> Base", "M4", "", 10, 65},
		{"whitespace tier -> Base", "M4", "   ", 10, 65},
		{"unknown tier -> Base", "M4", "Extreme", 10, 65},

		// Unknown family falls back to the GPU-core model.
		{"unknown family with gpu cores", "Intel", "", 16, 30 + 3.5*16},
		{"empty family with gpu cores", "", "Max", 24, 30 + 3.5*24},
		{"M6 future family", "M6", "Max", 50, 30 + 3.5*50},

		// gpuCores <= 0 in fallback returns the 30W floor.
		{"fallback zero gpu cores", "Intel", "", 0, 30},
		{"fallback negative gpu cores", "unknown", "", -5, 30},
		{"empty family no gpu cores", "", "", 0, 30},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := EstimateMachineWatts(tc.chipFamily, tc.chipTier, tc.gpuCores)
			if got != tc.want {
				t.Fatalf("EstimateMachineWatts(%q, %q, %d) = %v, want %v",
					tc.chipFamily, tc.chipTier, tc.gpuCores, got, tc.want)
			}
		})
	}
}
