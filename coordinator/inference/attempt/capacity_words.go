package attempt

import (
	"strings"
)

// ContainsWord reports whether word appears in s delimited by non-alphanumeric
// boundaries, so a short token like "oom" matches "gpu oom" but not "boom" or
// "room". word is assumed lowercase and alphanumeric; s is already lowercased.
func ContainsWord(s, word string) bool {
	for from := 0; from+len(word) <= len(s); {
		i := strings.Index(s[from:], word)
		if i < 0 {
			return false
		}
		start := from + i
		end := start + len(word)
		beforeOK := start == 0 || !isWordByte(s[start-1])
		afterOK := end == len(s) || !isWordByte(s[end])
		if beforeOK && afterOK {
			return true
		}
		from = start + 1
	}
	return false
}

func isWordByte(b byte) bool {
	return b == '_' ||
		(b >= 'a' && b <= 'z') ||
		(b >= 'A' && b <= 'Z') ||
		(b >= '0' && b <= '9')
}
