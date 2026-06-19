package api

import "testing"

func TestPromptBucket(t *testing.T) {
	cases := []struct {
		tokens int
		want   string
	}{
		// Below / smallest bucket, including the clamp for non-positive counts.
		{-100, "<1k"},
		{0, "<1k"},
		{1, "<1k"},
		{500, "<1k"},
		{999, "<1k"},
		// 1-4k (lower-inclusive, upper-exclusive).
		{1_000, "1-4k"},
		{2_500, "1-4k"},
		{3_999, "1-4k"},
		// 4-8k.
		{4_000, "4-8k"},
		{6_000, "4-8k"},
		{7_999, "4-8k"},
		// 8-16k (the long-prompt band where client_gone concentrates).
		{8_000, "8-16k"},
		{12_000, "8-16k"},
		{15_999, "8-16k"},
		// 16k+ (open-ended top bucket).
		{16_000, "16k+"},
		{28_000, "16k+"},
		{1_000_000, "16k+"},
	}
	for _, tc := range cases {
		if got := promptBucket(tc.tokens); got != tc.want {
			t.Errorf("promptBucket(%d) = %q, want %q", tc.tokens, got, tc.want)
		}
	}
}

// TestPromptBucketBoundariesAreContiguous asserts every boundary token lands in
// exactly the higher bucket (lower-inclusive), so no count is ever unbucketed or
// double-counted across the dashboard's grouping.
func TestPromptBucketBoundariesAreContiguous(t *testing.T) {
	boundaries := []struct {
		below, at int
		belowWant string
		atWant    string
	}{
		{999, 1_000, "<1k", "1-4k"},
		{3_999, 4_000, "1-4k", "4-8k"},
		{7_999, 8_000, "4-8k", "8-16k"},
		{15_999, 16_000, "8-16k", "16k+"},
	}
	for _, b := range boundaries {
		if got := promptBucket(b.below); got != b.belowWant {
			t.Errorf("promptBucket(%d) = %q, want %q", b.below, got, b.belowWant)
		}
		if got := promptBucket(b.at); got != b.atWant {
			t.Errorf("promptBucket(%d) = %q, want %q", b.at, got, b.atWant)
		}
	}
}

func TestEmitClientGoneNilDatadogNoPanic(t *testing.T) {
	// emitClientGone must be a safe no-op when Datadog is unconfigured (the
	// common test/dev path): ddIncr guards a nil client. An empty chip family
	// must not panic and is normalized to "unknown" inside the helper.
	s := &Server{}
	s.emitClientGone("gpt-oss-20b", 12_000, "", phaseBeforeFirstToken)
	s.emitClientGone("gpt-oss-20b", 500, "M3", phaseAfterCommit)
}
