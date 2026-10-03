package observation

func LowCardinalityCacheTier(tier string) string {
	if tier == "memory" || tier == "ssd" {
		return tier
	}
	return "none"
}
