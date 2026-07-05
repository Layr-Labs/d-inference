package api

import "testing"

func TestCalibratedContextPromptTokens(t *testing.T) {
	cases := []struct {
		name  string
		model string
		est   int
		want  int
	}{
		{"gpt_oss_scaled_1_3", "gpt-oss-20b", 100000, 130000},
		{"gpt_oss_alias_scaled", "gpt-oss", 10000, 13000},
		{"non_matching_family_unchanged", "gemma-4-26b-qat-4bit", 100000, 100000},
		{"zero_unchanged", "gpt-oss-20b", 0, 0},
		{"negative_unchanged", "gpt-oss-20b", -5, -5},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := calibratedContextPromptTokens(tc.model, tc.est); got != tc.want {
				t.Errorf("calibratedContextPromptTokens(%q, %d) = %d, want %d", tc.model, tc.est, got, tc.want)
			}
		})
	}
}

func TestSetPromptContextCalibrationFromEnv(t *testing.T) {
	// Snapshot + restore the package default so this test cannot leak into others.
	calibrationMu.Lock()
	saved := promptContextCalibration
	calibrationMu.Unlock()
	t.Cleanup(func() {
		calibrationMu.Lock()
		promptContextCalibration = saved
		calibrationMu.Unlock()
	})

	if n := SetPromptContextCalibrationFromEnv("gpt-oss:1.5,gemma:1.2"); n != 2 {
		t.Fatalf("applied pairs = %d, want 2", n)
	}
	if got := calibratedContextPromptTokens("gpt-oss-20b", 100000); got != 150000 {
		t.Errorf("after override, gpt-oss = %d, want 150000", got)
	}
	if got := calibratedContextPromptTokens("gemma-4-26b", 100000); got != 120000 {
		t.Errorf("after override, gemma = %d, want 120000", got)
	}

	// Blank / invalid input is a no-op (keeps whatever is currently configured).
	if n := SetPromptContextCalibrationFromEnv(""); n != 0 {
		t.Errorf("blank applied = %d, want 0", n)
	}
	if n := SetPromptContextCalibrationFromEnv("garbage,gpt-oss:notafloat,foo:0.5"); n != 0 {
		// 0.5 < 1.0 is rejected (would under-reject), the others are malformed.
		t.Errorf("all-invalid applied = %d, want 0", n)
	}
	// The last valid override (1.5) must still be in effect after the no-ops.
	if got := calibratedContextPromptTokens("gpt-oss-20b", 100000); got != 150000 {
		t.Errorf("after no-op overrides, gpt-oss = %d, want 150000 (unchanged)", got)
	}
}
