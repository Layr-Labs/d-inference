package api

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	maxReleasePayloadBytes int64 = 512 << 20
	maxReleasePlistBytes   int64 = 1 << 20
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
	releaseNestedAppPayloadSpecs = []releasePayloadSpec{
		{path: releaseNestedCLIPath, kind: releasePayloadBinary, mode: releaseExecutableMode},
		{path: releaseNestedAppPath + "/Contents/MacOS/darkbloom-enclave", kind: releasePayloadEnclave, mode: releaseExecutableMode},
		{path: releaseNestedAppPath + "/Contents/MacOS/mlx.metallib", kind: releasePayloadMetallib, mode: releaseDataMode},
	}
	releaseLegacyAppBaseFileSpecs = []releaseArtifactFileSpec{
		{path: "Darkbloom.app/Contents/Info.plist", mode: releaseDataMode},
		{path: "Darkbloom.app/Contents/embedded.provisionprofile", mode: releaseDataMode},
	}
	releaseGUIAppFileSpecs = []releaseArtifactFileSpec{
		{path: "Darkbloom.app/Contents/MacOS/DarkbloomApp", mode: releaseExecutableMode},
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
	releaseNestedAppBaseFileSpecs         = nestedReleaseArtifactFileSpecs(releaseLegacyAppBaseFileSpecs)
	releaseNestedPagedCapabilityFileSpecs = nestedReleaseArtifactFileSpecs(releasePagedCapabilityFileSpecs)
	releasePayloadSpecsByPath             = indexReleasePayloadSpecs(
		releaseFlatPayloadSpecs,
		releaseAppPayloadSpecs,
		releaseNestedAppPayloadSpecs,
	)
	releaseArtifactFileSpecsByPath = indexReleaseArtifactFileSpecs(
		releaseLegacyAppBaseFileSpecs,
		releaseGUIAppFileSpecs,
		releaseFanCapabilityFileSpecs,
		releasePagedCapabilityFileSpecs,
		releaseNestedAppBaseFileSpecs,
		releaseNestedPagedCapabilityFileSpecs,
	)
)

type releasePayload struct {
	hash               string
	hasFanCapability   bool
	hasPagedCapability bool
}

type releasePayloadCollector struct {
	found               map[string]releasePayload
	foundFiles          map[string]struct{}
	hasAppContent       bool
	hasNestedAppContent bool
	hasCLIAlias         bool
	plists              map[string][]byte
	profileHashes       map[string]string
}

func newReleasePayloadCollector() *releasePayloadCollector {
	return &releasePayloadCollector{
		found:         make(map[string]releasePayload, len(releasePayloadSpecsByPath)),
		foundFiles:    make(map[string]struct{}, len(releaseArtifactFileSpecsByPath)),
		plists:        make(map[string][]byte),
		profileHashes: make(map[string]string),
	}
}

// Mirror runtime resources into the nested CLI's bundle without widening the
// set of paths recognized as payloads or capability markers.
func nestedReleaseArtifactFileSpecs(specs []releaseArtifactFileSpec) []releaseArtifactFileSpec {
	nested := make([]releaseArtifactFileSpec, len(specs))
	for index, spec := range specs {
		spec.path = releaseNestedAppPath + strings.TrimPrefix(spec.path, "Darkbloom.app")
		nested[index] = spec
	}
	return nested
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

	nestedPath := foldReleaseArchivePath(releaseNestedAppPath)
	collector.hasNestedAppContent = collector.hasNestedAppContent ||
		foldedPath == nestedPath || strings.HasPrefix(foldedPath, nestedPath+"/")
	if entry.Path == releaseAppCLIAliasPath && entry.Kind == releaseArchiveSymlink {
		// validateReleaseArchive already checked the exact link bytes and will
		// require the regular target, with no link/file ancestors, at tar EOF.
		collector.hasCLIAlias = true
		return nil
	}

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
	if entry.Path == releaseLegacyAppBaseFileSpecs[0].path ||
		entry.Path == releaseNestedAppBaseFileSpecs[0].path {
		// Legacy bundles retain their old opaque-plist acceptance. Only the
		// nested layout parses these bounded bytes during final validation.
		data, err := io.ReadAll(io.LimitReader(contents, maxReleasePlistBytes+1))
		if err != nil {
			return fmt.Errorf("read release plist %q: %w", entry.Path, err)
		}
		collector.plists[entry.Path] = data
	}
	if entry.Path == releaseLegacyAppBaseFileSpecs[1].path ||
		entry.Path == releaseNestedAppBaseFileSpecs[1].path {
		hasher := sha256.New()
		if _, err := io.Copy(hasher, contents); err != nil {
			return fmt.Errorf("read release profile %q: %w", entry.Path, err)
		}
		collector.profileHashes[entry.Path] = hex.EncodeToString(hasher.Sum(nil))
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

	hasApp := false
	if collector.hasAppContent {
		if err := collector.requireFiles(releaseLegacyAppBaseFileSpecs); err != nil {
			return err
		}
		appSpecs := releaseAppPayloadSpecs
		if collector.hasCLIAlias || collector.hasNestedAppContent {
			if err := collector.validateNestedApp(release.Version); err != nil {
				return err
			}
			appSpecs = appSpecs[1:] // The outer CLI is the validated alias.
		}
		if err := collector.validatePayloadCopies(appSpecs, "app"); err != nil {
			return err
		}
		if collector.hasAnyFiles(releaseGUIAppFileSpecs) {
			if err := collector.requireFiles(releaseGUIAppFileSpecs); err != nil {
				return err
			}
			hasApp = true
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

	release.HasApp = &hasApp
	release.HasFanHelper = &hasFanHelper
	release.HasPagedKernel = &hasPagedKernel
	return nil
}

func (collector *releasePayloadCollector) validatePayloadCopies(specs []releasePayloadSpec, label string) error {
	if err := collector.require(specs); err != nil {
		return err
	}
	for _, spec := range specs {
		flatSpec := releaseFlatPayloadSpecs[spec.kind]
		if collector.found[spec.path].hash != collector.found[flatSpec.path].hash {
			return fmt.Errorf("%s and flat copies of %s do not match", label, releasePayloadKindName(spec.kind))
		}
	}
	return nil
}

func (collector *releasePayloadCollector) validateNestedApp(version string) error {
	if !collector.hasCLIAlias {
		return fmt.Errorf("nested provider app requires the exact outer CLI alias")
	}
	if err := collector.validatePayloadCopies(releaseNestedAppPayloadSpecs, "nested app"); err != nil {
		return err
	}
	if err := collector.requireFiles(releaseNestedAppBaseFileSpecs); err != nil {
		return err
	}
	if err := collector.requireFiles(releaseGUIAppFileSpecs); err != nil {
		return err
	}
	if collector.profileHashes[releaseLegacyAppBaseFileSpecs[1].path] !=
		collector.profileHashes[releaseNestedAppBaseFileSpecs[1].path] {
		return fmt.Errorf("outer and nested provider provisioning profiles differ")
	}
	for _, info := range []struct{ path, executable string }{
		{releaseLegacyAppBaseFileSpecs[0].path, "DarkbloomApp"},
		{releaseNestedAppBaseFileSpecs[0].path, "darkbloom"},
	} {
		if err := validateReleaseBundlePlist(collector.plists[info.path], info.executable, version); err != nil {
			return fmt.Errorf("release plist %q: %w", info.path, err)
		}
	}
	binary := collector.found[releaseNestedCLIPath]
	// Fan service assets stay anchored in the outer GUI app; only the paged
	// kernel is resolved relative to the nested CLI's own Resources directory.
	_, err := collector.validateCapability(binary.hasPagedCapability, releaseNestedPagedCapabilityFileSpecs, "nested paged-kernel")
	return err
}

// Only the new nested layout requires XML identity validation. The release
// bundler emits XML; external DTDs/entities are never loaded by encoding/xml.
// Profiles keep the same regular/nonempty/mode/size checks as the outer app;
// their bytes must match. Cryptographic signature/profile qualification
// belongs to the bundler.
func validateReleaseBundlePlist(data []byte, executable, version string) error {
	if int64(len(data)) > maxReleasePlistBytes {
		return fmt.Errorf("Info.plist exceeds the %d-byte limit", maxReleasePlistBytes)
	}
	want := map[string]string{
		"CFBundleExecutable":         executable,
		"CFBundleIdentifier":         "io.darkbloom.provider",
		"CFBundlePackageType":        "APPL",
		"CFBundleShortVersionString": strings.TrimPrefix(version, "v"),
		"CFBundleVersion":            strings.TrimPrefix(version, "v"),
	}
	decoder := xml.NewDecoder(bytes.NewReader(data))
	for _, name := range []string{"plist", "dict"} {
		token, err := nextReleasePlistToken(decoder)
		start, ok := token.(xml.StartElement)
		if err != nil || !ok || start.Name != (xml.Name{Local: name}) {
			return fmt.Errorf("Info.plist must contain one XML plist dictionary")
		}
	}
	seen := make(map[string]bool)
	for {
		token, err := nextReleasePlistToken(decoder)
		if err != nil {
			return fmt.Errorf("invalid Info.plist dictionary: %w", err)
		}
		if end, ok := token.(xml.EndElement); ok && end.Name == (xml.Name{Local: "dict"}) {
			break
		}
		keyStart, ok := token.(xml.StartElement)
		if !ok || keyStart.Name != (xml.Name{Local: "key"}) {
			return fmt.Errorf("Info.plist dictionary requires key/value pairs")
		}
		key, err := readReleasePlistText(decoder, keyStart)
		if err != nil {
			return err
		}
		if seen[key] {
			return fmt.Errorf("Info.plist repeats key %q", key)
		}
		seen[key] = true
		token, err = nextReleasePlistToken(decoder)
		valueStart, ok := token.(xml.StartElement)
		if err != nil || !ok || valueStart.Name.Space != "" || valueStart.Name.Local == "key" {
			return fmt.Errorf("Info.plist key %q is missing its value", key)
		}
		if expected, required := want[key]; required {
			if valueStart.Name.Local != "string" {
				return fmt.Errorf("Info.plist %s must be a string", key)
			}
			value, err := readReleasePlistText(decoder, valueStart)
			if err != nil {
				return err
			}
			if value != expected {
				return fmt.Errorf("Info.plist %s is %q; expected %q", key, value, expected)
			}
		} else if err := decoder.Skip(); err != nil {
			return fmt.Errorf("invalid Info.plist value for %q: %w", key, err)
		}
	}
	for key := range want {
		if !seen[key] {
			return fmt.Errorf("Info.plist is missing %s", key)
		}
	}
	token, err := nextReleasePlistToken(decoder)
	end, ok := token.(xml.EndElement)
	if err != nil || !ok || end.Name != (xml.Name{Local: "plist"}) {
		return fmt.Errorf("Info.plist must contain one dictionary")
	}
	if _, err := nextReleasePlistToken(decoder); err != io.EOF {
		return fmt.Errorf("Info.plist contains trailing content")
	}
	return nil
}

func nextReleasePlistToken(decoder *xml.Decoder) (xml.Token, error) {
	for {
		token, err := decoder.Token()
		if err != nil {
			return nil, err
		}
		switch value := token.(type) {
		case xml.Comment, xml.Directive, xml.ProcInst:
			continue
		case xml.CharData:
			if strings.TrimSpace(string(value)) != "" {
				return nil, fmt.Errorf("unexpected text in Info.plist")
			}
		default:
			return token, nil
		}
	}
}

func readReleasePlistText(decoder *xml.Decoder, start xml.StartElement) (string, error) {
	var text strings.Builder
	for {
		token, err := decoder.Token()
		if err != nil {
			return "", fmt.Errorf("invalid Info.plist text: %w", err)
		}
		switch value := token.(type) {
		case xml.CharData:
			text.Write(value)
		case xml.EndElement:
			if value.Name == start.Name {
				return text.String(), nil
			}
			return "", fmt.Errorf("invalid Info.plist text element")
		case xml.Comment:
		default:
			return "", fmt.Errorf("Info.plist %s must contain only text", start.Name.Local)
		}
	}
}

func (collector *releasePayloadCollector) hasAnyFiles(
	specs []releaseArtifactFileSpec,
) bool {
	for _, spec := range specs {
		if _, ok := collector.foundFiles[spec.path]; ok {
			return true
		}
	}
	return false
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
