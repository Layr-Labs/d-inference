package api

import (
	"fmt"
	"strings"
)

const releaseExecutableModeBits int64 = 0o111

// validateReleasePayloadPath keeps executable-bearing directories closed:
// adding a signed or launchable payload is a release-contract change, not
// something an archive may smuggle past the known hash checks.
func validateReleasePayloadPath(entry releaseArchiveEntry) error {
	for _, directory := range []string{
		"bin",
		"Darkbloom.app/Contents/MacOS",
		"Darkbloom.app/Contents/Helpers",
	} {
		if entry.Path == directory {
			continue
		}
		prefix := directory + "/"
		if !strings.HasPrefix(entry.Path, prefix) {
			continue
		}
		if _, known := releasePayloadSpecsByPath[entry.Path]; !known {
			return fmt.Errorf(
				"release archive contains unexpected payload %q",
				entry.Path,
			)
		}
	}

	if entry.Kind != releaseArchiveRegular ||
		entry.Mode&releaseExecutableModeBits == 0 ||
		!strings.HasPrefix(entry.Path, "Darkbloom.app/") {
		return nil
	}
	if _, known := releasePayloadSpecsByPath[entry.Path]; !known {
		return fmt.Errorf(
			"release app contains unexpected executable payload %q",
			entry.Path,
		)
	}
	return nil
}
