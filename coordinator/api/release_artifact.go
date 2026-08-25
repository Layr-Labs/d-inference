package api

import (
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
	releaseExecutableBits        = 0o111
)

type releasePayloadKind uint8

const (
	releasePayloadBinary releasePayloadKind = iota
	releasePayloadEnclave
	releasePayloadMetallib
)

type releasePayloadSpec struct {
	path       string
	kind       releasePayloadKind
	executable bool
}

var (
	releaseFlatPayloadSpecs = []releasePayloadSpec{
		{path: "bin/darkbloom", kind: releasePayloadBinary, executable: true},
		{path: "bin/darkbloom-enclave", kind: releasePayloadEnclave, executable: true},
		{path: "bin/mlx.metallib", kind: releasePayloadMetallib},
	}
	releaseAppPayloadSpecs = []releasePayloadSpec{
		{path: "Darkbloom.app/Contents/MacOS/darkbloom", kind: releasePayloadBinary, executable: true},
		{path: "Darkbloom.app/Contents/MacOS/darkbloom-enclave", kind: releasePayloadEnclave, executable: true},
		{path: "Darkbloom.app/Contents/MacOS/mlx.metallib", kind: releasePayloadMetallib},
	}
	releasePayloadSpecsByPath = indexReleasePayloadSpecs(
		releaseFlatPayloadSpecs,
		releaseAppPayloadSpecs,
	)
)

type releasePayload struct {
	hash string
}

type releasePayloadCollector struct {
	found  map[string]releasePayload
	hasApp bool
}

func newReleasePayloadCollector() *releasePayloadCollector {
	return &releasePayloadCollector{
		found: make(map[string]releasePayload, len(releasePayloadSpecsByPath)),
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
	if spec.executable {
		if entry.Mode&releaseExecutableBits == 0 {
			return fmt.Errorf("release payload %q is not executable", entry.Path)
		}
	} else if entry.Mode&releaseExecutableBits != 0 {
		return fmt.Errorf("release data payload %q must not be executable", entry.Path)
	}

	hasher := sha256.New()
	n, err := io.Copy(hasher, contents)
	if err != nil {
		return fmt.Errorf("read release payload %q: %w", entry.Path, err)
	}
	if n != entry.Size {
		return fmt.Errorf("release payload %q is truncated", entry.Path)
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
		return nil
	}
	if err := collector.require(releaseAppPayloadSpecs); err != nil {
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
