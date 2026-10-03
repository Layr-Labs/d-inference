package api

import "strings"

// Cache contract shared by composed HTTP endpoint tests.
const providerAttestationCacheKey = "providers:attestation:v1"

var (
	trHashA = strings.Repeat("a", 64)
	trHashB = strings.Repeat("b", 64)
	trHashC = strings.Repeat("c", 64)
)

func trBoolPtr(v bool) *bool { return &v }
