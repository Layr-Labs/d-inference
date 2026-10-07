package runtimepolicy

import (
	"sort"
	"strings"
)

// templateHashAccepted reports whether got is one of the accepted hashes for
// a template (case-insensitive; empty values never match).
func TemplateHashAccepted(accepted map[string]bool, got string) bool {
	got = strings.ToLower(strings.TrimSpace(got))
	return got != "" && accepted[got]
}

// sortedTemplateHashes lists a template's accepted hashes deterministically
// for diagnostics and the public manifest endpoint.
func SortedTemplateHashes(accepted map[string]bool) []string {
	out := make([]string, 0, len(accepted))
	for hash := range accepted {
		out = append(out, hash)
	}
	sort.Strings(out)
	return out
}
