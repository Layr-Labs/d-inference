package releases

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Controller) verifyReleaseArtifact(ctx context.Context, release *store.Release) error {
	downloadURL, err := s.trustedReleaseArtifactURL(release)
	if err != nil {
		return err
	}
	req := &http.Request{
		Method: http.MethodGet,
		URL:    downloadURL,
		Header: make(http.Header),
	}
	req = req.WithContext(ctx)

	client := &http.Client{
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
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
		tmp.Close()
		os.Remove(tmp.Name())
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
	actualBundleHash := hex.EncodeToString(bundleHash.Sum(nil))
	if actualBundleHash != release.BundleHash {
		return fmt.Errorf("bundle_hash does not match release artifact")
	}

	if _, err := tmp.Seek(0, io.SeekStart); err != nil {
		return fmt.Errorf("rewind bundle: %w", err)
	}

	gz, err := gzip.NewReader(tmp)
	if err != nil {
		return fmt.Errorf("open bundle gzip: %w", err)
	}
	defer gz.Close()

	tarReader := tar.NewReader(gz)
	binaryHash := sha256.New()
	foundBinary := false
	for {
		header, err := tarReader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("read bundle tar: %w", err)
		}
		cleanName, err := cleanReleaseTarPath(header.Name)
		if err != nil {
			return err
		}
		if cleanName != "bin/darkbloom" {
			continue
		}
		if header.Typeflag != tar.TypeReg && header.Typeflag != tar.TypeRegA {
			return fmt.Errorf("bundled provider binary is not a regular file")
		}
		if foundBinary {
			return fmt.Errorf("bundle contains multiple provider binaries")
		}
		if header.Size < 0 || header.Size > maxReleaseProviderBinBytes {
			return fmt.Errorf("provider binary exceeds maximum size")
		}
		n, err := io.Copy(binaryHash, io.LimitReader(tarReader, maxReleaseProviderBinBytes+1))
		if err != nil {
			return fmt.Errorf("read provider binary: %w", err)
		}
		if n > maxReleaseProviderBinBytes {
			return fmt.Errorf("provider binary exceeds maximum size")
		}
		foundBinary = true
	}
	if !foundBinary {
		return fmt.Errorf("bundle is missing bin/darkbloom")
	}

	actualBinaryHash := hex.EncodeToString(binaryHash.Sum(nil))
	if actualBinaryHash != release.BinaryHash {
		return fmt.Errorf("binary_hash does not match bundled provider binary")
	}
	return nil
}

func cleanReleaseTarPath(name string) (string, error) {
	if name == "" || strings.HasPrefix(name, "/") {
		return "", fmt.Errorf("bundle contains unsafe path")
	}
	for _, part := range strings.Split(name, "/") {
		if part == ".." {
			return "", fmt.Errorf("bundle contains unsafe path")
		}
	}
	return strings.TrimPrefix(path.Clean(name), "./"), nil
}
