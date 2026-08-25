package api

import (
	"bytes"
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// releaseBytePatternScanner finds capability strings while the coordinator is
// already streaming the registered binary through its SHA-256 hasher. It keeps
// only enough overlap to recognize a marker split across io.Copy buffers.
type releaseBytePatternScanner struct {
	patterns map[string][]byte
	found    map[string]bool
	tail     []byte
	maxLen   int
}

func newReleaseBytePatternScanner(patterns ...string) *releaseBytePatternScanner {
	scanner := &releaseBytePatternScanner{
		patterns: make(map[string][]byte, len(patterns)),
		found:    make(map[string]bool, len(patterns)),
	}
	for _, pattern := range patterns {
		scanner.patterns[pattern] = []byte(pattern)
		if len(pattern) > scanner.maxLen {
			scanner.maxLen = len(pattern)
		}
	}
	return scanner
}

func (scanner *releaseBytePatternScanner) Write(chunk []byte) (int, error) {
	combined := make([]byte, 0, len(scanner.tail)+len(chunk))
	combined = append(combined, scanner.tail...)
	combined = append(combined, chunk...)
	for name, pattern := range scanner.patterns {
		if !scanner.found[name] && bytes.Contains(combined, pattern) {
			scanner.found[name] = true
		}
	}

	overlap := scanner.maxLen - 1
	if overlap < 0 {
		overlap = 0
	}
	if overlap > len(combined) {
		overlap = len(combined)
	}
	scanner.tail = append(scanner.tail[:0], combined[len(combined)-overlap:]...)
	return len(chunk), nil
}

func (scanner *releaseBytePatternScanner) contains(pattern string) bool {
	return scanner.found[pattern]
}

func (collector *releasePayloadCollector) validateCapability(
	name string,
	binaryMarker string,
	specs []releasePayloadSpec,
) (bool, error) {
	codePresent := collector.binaryCapabilities.contains(binaryMarker)
	present := 0
	for _, spec := range specs {
		if _, ok := collector.found[spec.path]; ok {
			present++
		}
	}
	if !codePresent && present == 0 {
		return false, nil
	}
	if !codePresent || present != len(specs) {
		return false, fmt.Errorf(
			"%s capability requires matching binary code and all bundled payloads",
			name,
		)
	}
	return true, nil
}

func (collector *releasePayloadCollector) recordCapabilities(
	release *store.Release,
	hasApp bool,
	hasFanHelper bool,
	hasPagedKernel bool,
) error {
	if !hasApp &&
		(collector.binaryCapabilities.contains("darkbloom-fan-helper-v1") ||
			collector.binaryCapabilities.contains("engine_v2_kv_backend")) {
		return fmt.Errorf(
			"capability-bearing provider binaries require the Darkbloom.app layout",
		)
	}
	release.HasApp = boolPointer(hasApp)
	release.HasFanHelper = boolPointer(hasFanHelper)
	release.HasPagedKernel = boolPointer(hasPagedKernel)
	return nil
}

func boolPointer(value bool) *bool {
	return &value
}
