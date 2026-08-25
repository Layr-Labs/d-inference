// Package semver parses and compares canonical Semantic Versioning 2.0.0
// strings without constraining numeric identifiers to machine integer widths.
package semver

import (
	"fmt"
	"strings"
)

type identifier struct {
	value   string
	numeric bool
}

// Version is a parsed canonical SemVer 2 version. Build metadata is validated
// but intentionally omitted because it does not participate in precedence.
type Version struct {
	core       [3]string
	prerelease []identifier
}

// Parse validates and parses a canonical SemVer 2 string. A leading "v",
// incomplete core, leading zero in a numeric identifier, or non-ASCII
// identifier is rejected.
func Parse(raw string) (Version, error) {
	var version Version
	if raw == "" {
		return version, fmt.Errorf("version is empty")
	}

	withoutBuild, build, hasBuild := strings.Cut(raw, "+")
	if hasBuild {
		if withoutBuild == "" || build == "" || strings.Contains(build, "+") {
			return version, fmt.Errorf("invalid build metadata")
		}
		if _, ok := parseIdentifiers(build, true); !ok {
			return version, fmt.Errorf("invalid build metadata")
		}
	}

	core, prerelease, hasPrerelease := strings.Cut(withoutBuild, "-")
	parts := strings.Split(core, ".")
	if len(parts) != len(version.core) {
		return version, fmt.Errorf("version core must contain major, minor, and patch")
	}
	for index, part := range parts {
		if !validNumeric(part, false) {
			return version, fmt.Errorf("invalid core identifier %q", part)
		}
		version.core[index] = part
	}

	if hasPrerelease {
		identifiers, ok := parseIdentifiers(prerelease, false)
		if !ok {
			return Version{}, fmt.Errorf("invalid prerelease")
		}
		version.prerelease = identifiers
	}
	return version, nil
}

// IsValid reports whether raw is a canonical SemVer 2 string.
func IsValid(raw string) bool {
	_, err := Parse(raw)
	return err == nil
}

// Compare parses and compares two canonical SemVer 2 strings. It returns -1,
// 0, or 1. Build metadata does not affect the result.
func Compare(left, right string) (int, error) {
	leftVersion, err := Parse(left)
	if err != nil {
		return 0, fmt.Errorf("invalid left version %q: %w", left, err)
	}
	rightVersion, err := Parse(right)
	if err != nil {
		return 0, fmt.Errorf("invalid right version %q: %w", right, err)
	}
	return leftVersion.Compare(rightVersion), nil
}

// Compare returns -1, 0, or 1 according to SemVer 2 precedence.
func (version Version) Compare(other Version) int {
	for index, left := range version.core {
		if comparison := compareNumeric(left, other.core[index]); comparison != 0 {
			return comparison
		}
	}

	switch {
	case len(version.prerelease) == 0 && len(other.prerelease) == 0:
		return 0
	case len(version.prerelease) == 0:
		return 1
	case len(other.prerelease) == 0:
		return -1
	}

	count := min(len(version.prerelease), len(other.prerelease))
	for index := 0; index < count; index++ {
		left := version.prerelease[index]
		right := other.prerelease[index]
		if left.value == right.value && left.numeric == right.numeric {
			continue
		}
		switch {
		case left.numeric && right.numeric:
			if comparison := compareNumeric(left.value, right.value); comparison != 0 {
				return comparison
			}
		case left.numeric:
			return -1
		case right.numeric:
			return 1
		case left.value < right.value:
			return -1
		default:
			return 1
		}
	}
	return compareLength(len(version.prerelease), len(other.prerelease))
}

func parseIdentifiers(raw string, numericLeadingZeroAllowed bool) ([]identifier, bool) {
	parts := strings.Split(raw, ".")
	if len(parts) == 0 {
		return nil, false
	}
	identifiers := make([]identifier, 0, len(parts))
	for _, part := range parts {
		if part == "" {
			return nil, false
		}
		numeric := true
		for index := 0; index < len(part); index++ {
			character := part[index]
			if character < '0' || character > '9' {
				numeric = false
			}
			if !isASCIIIdentifierCharacter(character) {
				return nil, false
			}
		}
		if numeric && !validNumeric(part, numericLeadingZeroAllowed) {
			return nil, false
		}
		identifiers = append(identifiers, identifier{
			value:   part,
			numeric: numeric,
		})
	}
	return identifiers, true
}

func validNumeric(raw string, leadingZeroAllowed bool) bool {
	if raw == "" {
		return false
	}
	for index := 0; index < len(raw); index++ {
		if raw[index] < '0' || raw[index] > '9' {
			return false
		}
	}
	return leadingZeroAllowed || raw == "0" || raw[0] != '0'
}

func isASCIIIdentifierCharacter(character byte) bool {
	return character >= '0' && character <= '9' ||
		character >= 'A' && character <= 'Z' ||
		character >= 'a' && character <= 'z' ||
		character == '-'
}

func compareNumeric(left, right string) int {
	if comparison := compareLength(len(left), len(right)); comparison != 0 {
		return comparison
	}
	switch {
	case left < right:
		return -1
	case left > right:
		return 1
	default:
		return 0
	}
}

func compareLength(left, right int) int {
	switch {
	case left < right:
		return -1
	case left > right:
		return 1
	default:
		return 0
	}
}
