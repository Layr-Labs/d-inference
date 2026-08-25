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
)

type releasePayloadKind uint8

const (
	releasePayloadBinary releasePayloadKind = iota
	releasePayloadEnclave
	releasePayloadMetallib
)

type releasePayloadSpec struct {
	path            string
	kind            releasePayloadKind
	mode            int64
	expectedContent string
}

var (
	releaseFlatPayloadSpecs = []releasePayloadSpec{
		{path: "bin/darkbloom", kind: releasePayloadBinary, mode: 0o755},
		{path: "bin/darkbloom-enclave", kind: releasePayloadEnclave, mode: 0o755},
		{path: "bin/mlx.metallib", kind: releasePayloadMetallib, mode: 0o644},
	}
	releaseAppPayloadSpecs = []releasePayloadSpec{
		{path: "Darkbloom.app/Contents/MacOS/darkbloom", kind: releasePayloadBinary, mode: 0o755},
		{path: "Darkbloom.app/Contents/MacOS/darkbloom-enclave", kind: releasePayloadEnclave, mode: 0o755},
		{path: "Darkbloom.app/Contents/MacOS/mlx.metallib", kind: releasePayloadMetallib, mode: 0o644},
	}
	releaseAppIdentityPayloadSpecs = []releasePayloadSpec{
		{path: "Darkbloom.app/Contents/MacOS/DarkbloomApp", mode: 0o755},
	}
	releaseAppRequiredDataPayloadSpecs = []releasePayloadSpec{
		{path: "Darkbloom.app/Contents/Info.plist", mode: 0o644},
		{path: "Darkbloom.app/Contents/embedded.provisionprofile", mode: 0o644},
		{path: "Darkbloom.app/Contents/_CodeSignature/CodeResources", mode: 0o644},
		{path: "Darkbloom.app/Contents/Resources/Chivo-Regular.ttf", mode: 0o644},
		{path: "Darkbloom.app/Contents/Resources/Chivo-Medium.ttf", mode: 0o644},
		{
			path: "Darkbloom.app/Contents/Resources/DarkbloomProvider_DarkbloomApp.bundle/default.metallib",
			mode: 0o644,
		},
	}
	releaseFanCapabilityPayloadSpecs = []releasePayloadSpec{
		{path: "Darkbloom.app/Contents/Helpers/darkbloom-fan-helper", mode: 0o755},
		{
			path:            "Darkbloom.app/Contents/Resources/darkbloom-runtime-capabilities/fan-helper-v1",
			mode:            0o644,
			expectedContent: "1\n",
		},
	}
	releasePagedCapabilityPayloadSpecs = []releasePayloadSpec{
		{
			path:            "Darkbloom.app/Contents/Resources/darkbloom-runtime-capabilities/paged-kernel-v1",
			mode:            0o644,
			expectedContent: "1\n",
		},
		{
			path: "Darkbloom.app/Contents/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal",
			mode: 0o644,
		},
	}
	releasePayloadSpecsByPath = indexReleasePayloadSpecs(
		releaseFlatPayloadSpecs,
		releaseAppPayloadSpecs,
		releaseAppIdentityPayloadSpecs,
		releaseAppRequiredDataPayloadSpecs,
		releaseFanCapabilityPayloadSpecs,
		releasePagedCapabilityPayloadSpecs,
	)
)

type releasePayload struct {
	hash string
}

type releasePayloadCollector struct {
	found              map[string]releasePayload
	hasApp             bool
	binaryCapabilities *releaseBytePatternScanner
}

func newReleasePayloadCollector() *releasePayloadCollector {
	return &releasePayloadCollector{
		found: make(map[string]releasePayload, len(releasePayloadSpecsByPath)),
		binaryCapabilities: newReleaseBytePatternScanner(
			"darkbloom-fan-helper-v1",
			"engine_v2_kv_backend",
		),
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

func (collector *releasePayloadCollector) visit(
	entry releaseArchiveEntry,
	contents io.Reader,
) error {
	if err := validateReleasePayloadPath(entry); err != nil {
		return err
	}
	foldedPath := foldReleaseArchivePath(entry.Path)
	collector.hasApp = collector.hasApp ||
		foldedPath == "darkbloom.app" ||
		strings.HasPrefix(foldedPath, "darkbloom.app/")

	spec, required := releasePayloadSpecsByPath[entry.Path]
	if !required {
		return nil
	}
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
			"release payload %q has mode %#o, want %#o",
			entry.Path,
			entry.Mode,
			spec.mode,
		)
	}
	if spec.expectedContent != "" &&
		entry.Size != int64(len(spec.expectedContent)) {
		return fmt.Errorf("release payload %q has invalid contents", entry.Path)
	}

	hasher := sha256.New()
	writers := []io.Writer{hasher}
	if entry.Path == releaseFlatPayloadSpecs[0].path {
		writers = append(writers, collector.binaryCapabilities)
	}
	var captured bytes.Buffer
	if spec.expectedContent != "" {
		writers = append(writers, &captured)
	}
	n, err := io.Copy(io.MultiWriter(writers...), contents)
	if err != nil {
		return fmt.Errorf("read release payload %q: %w", entry.Path, err)
	}
	if n != entry.Size {
		return fmt.Errorf("release payload %q is truncated", entry.Path)
	}
	if spec.expectedContent != "" &&
		captured.String() != spec.expectedContent {
		return fmt.Errorf("release payload %q has invalid contents", entry.Path)
	}
	collector.found[entry.Path] = releasePayload{
		hash: hex.EncodeToString(hasher.Sum(nil)),
	}
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

	if !collector.hasApp {
		return collector.recordCapabilities(release, false, false, false)
	}
	if err := collector.require(releaseAppPayloadSpecs); err != nil {
		return err
	}
	if err := collector.require(releaseAppIdentityPayloadSpecs); err != nil {
		return err
	}
	if err := collector.require(releaseAppRequiredDataPayloadSpecs); err != nil {
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

	hasFanHelper, err := collector.validateCapability(
		"fan helper",
		"darkbloom-fan-helper-v1",
		releaseFanCapabilityPayloadSpecs,
	)
	if err != nil {
		return err
	}
	hasPagedKernel, err := collector.validateCapability(
		"paged kernel",
		"engine_v2_kv_backend",
		releasePagedCapabilityPayloadSpecs,
	)
	if err != nil {
		return err
	}
	return collector.recordCapabilities(
		release,
		true,
		hasFanHelper,
		hasPagedKernel,
	)
}

func (collector *releasePayloadCollector) require(specs []releasePayloadSpec) error {
	for _, spec := range specs {
		if _, ok := collector.found[spec.path]; !ok {
			return fmt.Errorf("bundle is missing required release payload %q", spec.path)
		}
	}
	return nil
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
