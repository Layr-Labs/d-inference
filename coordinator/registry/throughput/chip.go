package throughput

import "strings"

// chipBandwidthGBps maps an Apple-Silicon chip class to its approximate peak
// unified-memory bandwidth (GB/s). Values are nominal datasheet peaks; the
// detector multiplies by the efficiency factor to get a sustained estimate. A
// provider-reported memory_bandwidth_gbs, when present, takes precedence over
// this table (resolved in the api sweep); this table is the fallback for
// providers that omit it. M4 Ultra / the M5 line are approximate/extrapolated.
var chipBandwidthGBps = map[string]float64{
	"M1":       68,
	"M1 Pro":   200,
	"M1 Max":   400,
	"M1 Ultra": 800,
	"M2":       100,
	"M2 Pro":   200,
	"M2 Max":   400,
	"M2 Ultra": 800,
	"M3":       100,
	"M3 Pro":   150,
	"M3 Max":   400,
	"M3 Ultra": 800,
	"M4":       120,
	"M4 Pro":   273,
	"M4 Max":   546,
	"M4 Ultra": 1092,
	"M5":       153,
	"M5 Pro":   300,
	"M5 Max":   600,
	"M5 Ultra": 1200,
}

// NormalizeChipClass builds a canonical chip-class string ("M3 Max", "M4 Pro",
// "M2") from a provider-reported chip family and tier. Returns "" when no Apple
// generation token can be found.
func NormalizeChipClass(family, tier string) string {
	return chipClassFromTokens(family + " " + tier)
}

// ResolveChipClass derives a canonical chip class from a provider's reported
// chip family and tier, falling back to the marketing chip name ("Apple M3 Max")
// when family/tier are empty or unrecognized. Returns "" when nothing resolves.
func ResolveChipClass(family, tier, chipName string) string {
	if c := chipClassFromTokens(family + " " + tier); c != "" {
		return c
	}
	return chipClassFromTokens(chipName)
}

// chipClassFromTokens scans a string for an Apple-Silicon generation token
// (M1..M9, case-insensitive) and an optional tier (Pro/Max/Ultra) and returns
// the canonical class ("M3 Max"), or "" if no generation token is present.
func chipClassFromTokens(s string) string {
	gen := ""
	tier := ""
	for _, tok := range strings.Fields(s) {
		switch strings.ToLower(tok) {
		case "pro":
			tier = "Pro"
		case "max":
			tier = "Max"
		case "ultra":
			tier = "Ultra"
		default:
			if gen == "" && isAppleGenToken(tok) {
				gen = strings.ToUpper(tok) // "m3" → "M3"
			}
		}
	}
	if gen == "" {
		return ""
	}
	if tier == "" {
		return gen
	}
	return gen + " " + tier
}

// isAppleGenToken reports whether tok looks like "M<digits>" (e.g. m1..m5),
// case-insensitive.
func isAppleGenToken(tok string) bool {
	if len(tok) < 2 {
		return false
	}
	if tok[0] != 'm' && tok[0] != 'M' {
		return false
	}
	for _, r := range tok[1:] {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// ChipBandwidthForClass returns the table bandwidth (GB/s) for a chip class,
// falling back to the bare generation ("M3 Max" → "M3") when the exact tier is
// unknown, then 0 when the generation itself is unknown. Underestimating an
// unknown tier (using the base generation) is the safe direction: it lowers the
// expectation, raising the observed/expected ratio, so it cannot manufacture a
// false anomaly.
func (p Policy) ChipBandwidthForClass(class string) float64 {
	if class == "" {
		return 0
	}
	if bw, ok := p.ChipBandwidth[class]; ok {
		return bw
	}
	if i := strings.IndexByte(class, ' '); i > 0 {
		if bw, ok := p.ChipBandwidth[class[:i]]; ok {
			return bw
		}
	}
	return 0
}
