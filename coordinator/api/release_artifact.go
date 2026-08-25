package api

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	maxReleasePayloadBytes int64 = 512 << 20
	releaseExecutableMode  int64 = 0o755
	releaseDataMode        int64 = 0o644

	releaseFanCapabilityMarker   = "darkbloom-fan-helper-v1"
	releasePagedCapabilityMarker = "engine_v2_kv_backend"
)

type releasePayloadKind uint8

const (
	releasePayloadBinary releasePayloadKind = iota
	releasePayloadEnclave
	releasePayloadMetallib
)

type releasePayloadSpec struct {
	path string
	kind releasePayloadKind
	mode int64
}

type releaseArtifactFileSpec struct {
	path          string
	mode          int64
	exactContents string
}

var (
	releaseFlatPayloadSpecs = []releasePayloadSpec{
		{path: "bin/darkbloom", kind: releasePayloadBinary, mode: releaseExecutableMode},
		{path: "bin/darkbloom-enclave", kind: releasePayloadEnclave, mode: releaseExecutableMode},
		{path: "bin/mlx.metallib", kind: releasePayloadMetallib, mode: releaseDataMode},
	}
	releaseAppPayloadSpecs = []releasePayloadSpec{
		{path: "Darkbloom.app/Contents/MacOS/darkbloom", kind: releasePayloadBinary, mode: releaseExecutableMode},
		{path: "Darkbloom.app/Contents/MacOS/darkbloom-enclave", kind: releasePayloadEnclave, mode: releaseExecutableMode},
		{path: "Darkbloom.app/Contents/MacOS/mlx.metallib", kind: releasePayloadMetallib, mode: releaseDataMode},
	}
	releaseAppBaseFileSpecs = []releaseArtifactFileSpec{
		{path: "Darkbloom.app/Contents/MacOS/DarkbloomApp", mode: releaseExecutableMode},
		{path: "Darkbloom.app/Contents/Info.plist", mode: releaseDataMode},
		{path: "Darkbloom.app/Contents/embedded.provisionprofile", mode: releaseDataMode},
		{path: "Darkbloom.app/Contents/Resources/Chivo-Regular.ttf", mode: releaseDataMode},
		{path: "Darkbloom.app/Contents/Resources/Chivo-Medium.ttf", mode: releaseDataMode},
		{
			path: "Darkbloom.app/Contents/Resources/" +
				"DarkbloomProvider_DarkbloomApp.bundle/default.metallib",
			mode: releaseDataMode,
		},
	}
	releaseFanCapabilityFileSpecs = []releaseArtifactFileSpec{
		{
			path:          "Darkbloom.app/Contents/Resources/darkbloom-runtime-capabilities/fan-helper-v1",
			mode:          releaseDataMode,
			exactContents: "1\n",
		},
		{
			path: "Darkbloom.app/Contents/Helpers/darkbloom-fan-helper",
			mode: releaseExecutableMode,
		},
	}
	releasePagedCapabilityFileSpecs = []releaseArtifactFileSpec{
		{
			path:          "Darkbloom.app/Contents/Resources/darkbloom-runtime-capabilities/paged-kernel-v1",
			mode:          releaseDataMode,
			exactContents: "1\n",
		},
		{
			path: "Darkbloom.app/Contents/Resources/" +
				"mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal",
			mode: releaseDataMode,
		},
	}
	releasePayloadSpecsByPath = indexReleasePayloadSpecs(
		releaseFlatPayloadSpecs,
		releaseAppPayloadSpecs,
	)
	releaseArtifactFileSpecsByPath = indexReleaseArtifactFileSpecs(
		releaseAppBaseFileSpecs,
		releaseFanCapabilityFileSpecs,
		releasePagedCapabilityFileSpecs,
	)
)

type releasePayload struct {
	hash               string
	hasFanCapability   bool
	hasPagedCapability bool
}

type releasePayloadCollector struct {
	found         map[string]releasePayload
	foundFiles    map[string]struct{}
	hasAppContent bool
}

func newReleasePayloadCollector() *releasePayloadCollector {
	return &releasePayloadCollector{
		found:      make(map[string]releasePayload, len(releasePayloadSpecsByPath)),
		foundFiles: make(map[string]struct{}, len(releaseArtifactFileSpecsByPath)),
	}
}

func indexReleasePayloadSpecs(groups ...[]releasePayloadSpec) map[string]releasePayloadSpec {
	total := 0
	for _, group := range groups {
		total += len(group)
	}
	indexed := make(map[string]releasePayloadSpec, total)
	for _, group := range groups {
		for _, spec := range group {
			indexed[spec.path] = spec
		}
	}
	return indexed
}

func indexReleaseArtifactFileSpecs(
	groups ...[]releaseArtifactFileSpec,
) map[string]releaseArtifactFileSpec {
	total := 0
	for _, group := range groups {
		total += len(group)
	}
	indexed := make(map[string]releaseArtifactFileSpec, total)
	for _, group := range groups {
		for _, spec := range group {
			indexed[spec.path] = spec
		}
	}
	return indexed
}

func (collector *releasePayloadCollector) visit(
	entry releaseArchiveEntry,
	contents io.Reader,
) error {
	foldedPath := foldReleaseArchivePath(entry.Path)
	collector.hasAppContent = collector.hasAppContent ||
		foldedPath == "darkbloom.app" ||
		strings.HasPrefix(foldedPath, "darkbloom.app/")

	if spec, required := releasePayloadSpecsByPath[entry.Path]; required {
		return collector.collectPayload(entry, contents, spec)
	}
	if spec, tracked := releaseArtifactFileSpecsByPath[entry.Path]; tracked {
		return collector.collectArtifactFile(entry, contents, spec)
	}
	return nil
}

func (collector *releasePayloadCollector) collectPayload(
	entry releaseArchiveEntry,
	contents io.Reader,
	spec releasePayloadSpec,
) error {
	if entry.Kind != releaseArchiveRegular {
		return fmt.Errorf("release payload %q is not a regular file", entry.Path)
	}
	if _, duplicate := collector.found[entry.Path]; duplicate {
		return fmt.Errorf("bundle contains multiple copies of release payload %q", entry.Path)
	}
	if entry.Size == 0 {
		return fmt.Errorf("release payload %q is empty", entry.Path)
	}
	if entry.Size > maxReleasePayloadBytes {
		return fmt.Errorf(
			"release payload %q exceeds the %d-byte limit",
			entry.Path,
			maxReleasePayloadBytes,
		)
	}
	if entry.Mode != spec.mode {
		return fmt.Errorf(
			"release payload %q has mode %04o; expected %04o",
			entry.Path,
			entry.Mode,
			spec.mode,
		)
	}

	hasher := sha256.New()
	scanner := newReleaseMarkerScanner(
		[]byte(releaseFanCapabilityMarker),
		[]byte(releasePagedCapabilityMarker),
	)
	writer := io.Writer(hasher)
	if spec.kind == releasePayloadBinary {
		writer = io.MultiWriter(hasher, scanner)
	}
	n, err := io.Copy(writer, contents)
	if err != nil {
		return fmt.Errorf("read release payload %q: %w", entry.Path, err)
	}
	if n != entry.Size {
		return fmt.Errorf("release payload %q is truncated", entry.Path)
	}
	collector.found[entry.Path] = releasePayload{
		hash:               hex.EncodeToString(hasher.Sum(nil)),
		hasFanCapability:   scanner.found(0),
		hasPagedCapability: scanner.found(1),
	}
	return nil
}

func (collector *releasePayloadCollector) collectArtifactFile(
	entry releaseArchiveEntry,
	contents io.Reader,
	spec releaseArtifactFileSpec,
) error {
	if entry.Kind != releaseArchiveRegular {
		return fmt.Errorf("release artifact file %q is not a regular file", entry.Path)
	}
	if _, duplicate := collector.foundFiles[entry.Path]; duplicate {
		return fmt.Errorf("bundle contains multiple copies of release artifact file %q", entry.Path)
	}
	if entry.Size == 0 {
		return fmt.Errorf("release artifact file %q is empty", entry.Path)
	}
	if entry.Size > maxReleasePayloadBytes {
		return fmt.Errorf(
			"release artifact file %q exceeds the %d-byte limit",
			entry.Path,
			maxReleasePayloadBytes,
		)
	}
	if entry.Mode != spec.mode {
		return fmt.Errorf(
			"release artifact file %q has mode %04o; expected %04o",
			entry.Path,
			entry.Mode,
			spec.mode,
		)
	}
	if spec.exactContents != "" {
		if entry.Size != int64(len(spec.exactContents)) {
			return fmt.Errorf("release artifact marker %q has invalid contents", entry.Path)
		}
		actual, err := io.ReadAll(contents)
		if err != nil {
			return fmt.Errorf("read release artifact marker %q: %w", entry.Path, err)
		}
		if string(actual) != spec.exactContents {
			return fmt.Errorf("release artifact marker %q has invalid contents", entry.Path)
		}
	}
	collector.foundFiles[entry.Path] = struct{}{}
	return nil
}

func (collector *releasePayloadCollector) validate(release *store.Release) error {
	if err := collector.require(releaseFlatPayloadSpecs); err != nil {
		return err
	}

	flatBinary := collector.found[releaseFlatPayloadSpecs[0].path]
	if flatBinary.hash != release.BinaryHash {
		return fmt.Errorf("binary_hash does not match bundled provider binary")
	}
	flatMetallib := collector.found[releaseFlatPayloadSpecs[2].path]
	if release.MetallibHash != "" && flatMetallib.hash != release.MetallibHash {
		return fmt.Errorf("metallib_hash does not match bundled mlx.metallib")
	}

	if collector.hasAppContent {
		if err := collector.require(releaseAppPayloadSpecs); err != nil {
			return err
		}
		if err := collector.requireFiles(releaseAppBaseFileSpecs); err != nil {
			return err
		}
		for index, appSpec := range releaseAppPayloadSpecs {
			flatSpec := releaseFlatPayloadSpecs[index]
			if collector.found[appSpec.path].hash != collector.found[flatSpec.path].hash {
				return fmt.Errorf(
					"app and flat copies of %s do not match",
					releasePayloadKindName(appSpec.kind),
				)
			}
		}
	}

	hasFanHelper, err := collector.validateCapability(
		flatBinary.hasFanCapability,
		releaseFanCapabilityFileSpecs,
		"fan-helper",
	)
	if err != nil {
		return err
	}
	hasPagedKernel, err := collector.validateCapability(
		flatBinary.hasPagedCapability,
		releasePagedCapabilityFileSpecs,
		"paged-kernel",
	)
	if err != nil {
		return err
	}

	hasApp := collector.hasAppContent
	release.HasApp = &hasApp
	release.HasFanHelper = &hasFanHelper
	release.HasPagedKernel = &hasPagedKernel
	return nil
}

func (collector *releasePayloadCollector) require(specs []releasePayloadSpec) error {
	for _, spec := range specs {
		if _, ok := collector.found[spec.path]; !ok {
			return fmt.Errorf("bundle is missing required release payload %q", spec.path)
		}
	}
	return nil
}

func (collector *releasePayloadCollector) requireFiles(
	specs []releaseArtifactFileSpec,
) error {
	for _, spec := range specs {
		if _, ok := collector.foundFiles[spec.path]; !ok {
			return fmt.Errorf("bundle is missing required release artifact file %q", spec.path)
		}
	}
	return nil
}

func (collector *releasePayloadCollector) validateCapability(
	codePresent bool,
	specs []releaseArtifactFileSpec,
	name string,
) (bool, error) {
	present := 0
	for _, spec := range specs {
		if _, ok := collector.foundFiles[spec.path]; ok {
			present++
		}
	}
	if !codePresent && present == 0 {
		return false, nil
	}
	if !codePresent || present != len(specs) {
		return false, fmt.Errorf(
			"%s capability code and artifact files must be present together",
			name,
		)
	}
	return true, nil
}

type releaseMarkerScanner struct {
	markers [][]byte
	matches []bool
	tail    []byte
	maxLen  int
}

func newReleaseMarkerScanner(markers ...[]byte) *releaseMarkerScanner {
	scanner := &releaseMarkerScanner{
		markers: markers,
		matches: make([]bool, len(markers)),
	}
	for _, marker := range markers {
		if len(marker) > scanner.maxLen {
			scanner.maxLen = len(marker)
		}
	}
	return scanner
}

func (scanner *releaseMarkerScanner) Write(chunk []byte) (int, error) {
	window := make([]byte, len(scanner.tail)+len(chunk))
	copy(window, scanner.tail)
	copy(window[len(scanner.tail):], chunk)
	for index, marker := range scanner.markers {
		if !scanner.matches[index] && bytes.Contains(window, marker) {
			scanner.matches[index] = true
		}
	}
	keep := scanner.maxLen - 1
	if keep > len(window) {
		keep = len(window)
	}
	scanner.tail = append(scanner.tail[:0], window[len(window)-keep:]...)
	return len(chunk), nil
}

func (scanner *releaseMarkerScanner) found(index int) bool {
	return index >= 0 && index < len(scanner.matches) && scanner.matches[index]
}

func releasePayloadKindName(kind releasePayloadKind) string {
	switch kind {
	case releasePayloadBinary:
		return "darkbloom"
	case releasePayloadEnclave:
		return "darkbloom-enclave"
	case releasePayloadMetallib:
		return "mlx.metallib"
	default:
		return "unknown payload"
	}
}

func (s *Server) verifyReleaseArtifact(ctx context.Context, release *store.Release) error {
	downloadURL, err := s.trustedReleaseArtifactURL(release)
	if err != nil {
		return err
	}
	req := (&http.Request{
		Method: http.MethodGet,
		URL:    downloadURL,
		Header: make(http.Header),
	}).WithContext(ctx)

	client := &http.Client{
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("download bundle: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download bundle returned status %d", resp.StatusCode)
	}

	tmp, err := os.CreateTemp("", "darkbloom-release-*.tar.gz")
	if err != nil {
		return fmt.Errorf("create temp bundle: %w", err)
	}
	defer func() {
		_ = tmp.Close()
		_ = os.Remove(tmp.Name())
	}()

	bundleHash := sha256.New()
	limited := io.LimitReader(resp.Body, maxReleaseArtifactBytes+1)
	n, err := io.Copy(io.MultiWriter(tmp, bundleHash), limited)
	if err != nil {
		return fmt.Errorf("read bundle: %w", err)
	}
	if n > maxReleaseArtifactBytes {
		return fmt.Errorf("bundle exceeds maximum size")
	}
	if hex.EncodeToString(bundleHash.Sum(nil)) != release.BundleHash {
		return fmt.Errorf("bundle_hash does not match release artifact")
	}
	if _, err := tmp.Seek(0, io.SeekStart); err != nil {
		return fmt.Errorf("rewind bundle: %w", err)
	}

	gz, err := gzip.NewReader(tmp)
	if err != nil {
		return fmt.Errorf("open bundle gzip: %w", err)
	}
	collector := newReleasePayloadCollector()
	if err := validateReleaseArchive(
		gz,
		defaultReleaseArchivePolicy,
		collector.visit,
	); err != nil {
		_ = gz.Close()
		return fmt.Errorf("validate bundle archive: %w", err)
	}
	if err := gz.Close(); err != nil {
		return fmt.Errorf("close bundle gzip: %w", err)
	}
	return collector.validate(release)
}
