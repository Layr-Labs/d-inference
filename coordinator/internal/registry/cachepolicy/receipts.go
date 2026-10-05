package cachepolicy

func Outcome(outcome string) bool {
	switch outcome {
	case "hit", "miss_absent", "miss_corrupt", "skipped_capacity", "skipped_cost", "skipped_policy":
		return true
	default:
		return false
	}
}
