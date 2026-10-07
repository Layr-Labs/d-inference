package artifacts

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"

	identity "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/identity"
)

func (c *ArtifactCache) downloadArtifact(ctx context.Context, root *os.Root, prefix string, artifact identity.Artifact) error {
	if !identity.ValidRelativePath(artifact.Path) {
		return ErrUnsafeArtifactPath
	}
	parent := path.Dir(artifact.Path)
	if parent != "." {
		if err := secureMkdirAll(root, parent, 0o700); err != nil {
			return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
		}
	}
	target := *c.baseURL
	target.Path = path.Join(c.baseURL.Path, prefix, artifact.Path)
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, target.String(), nil)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
	}
	response, err := c.httpClient.Do(request)
	if err != nil {
		if errors.Is(err, ErrArtifactIntegrity) {
			return ErrArtifactIntegrity
		}
		return fmt.Errorf("%w: %w", ErrArtifactUnavailable, err)
	}
	defer response.Body.Close()
	if response.Request.URL.Scheme != c.baseURL.Scheme ||
		response.Request.URL.Host != c.baseURL.Host {
		return ErrArtifactIntegrity
	}
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("%w: HTTP %d", ErrArtifactUnavailable, response.StatusCode)
	}
	if response.ContentLength >= 0 && response.ContentLength != artifact.SizeBytes {
		return ErrArtifactIntegrity
	}
	file, err := secureCreate(root, artifact.Path, 0o600)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
	}
	success := false
	defer func() {
		_ = file.Close()
		if !success {
			_ = root.Remove(artifact.Path)
		}
	}()
	hasher := sha256.New()
	written, err := io.Copy(io.MultiWriter(file, hasher), io.LimitReader(response.Body, artifact.SizeBytes+1))
	if err != nil {
		return fmt.Errorf("%w: %w", ErrArtifactUnavailable, err)
	}
	if written != artifact.SizeBytes {
		return ErrArtifactIntegrity
	}
	var extra [1]byte
	if read, readErr := response.Body.Read(extra[:]); read > 0 || (readErr != nil && !errors.Is(readErr, io.EOF)) {
		return ErrArtifactIntegrity
	}
	expected, err := identity.ParseDigest(artifact.SHA256)
	if err != nil || !equalBytes(hasher.Sum(nil), expected) {
		return ErrArtifactIntegrity
	}
	if err := file.Sync(); err != nil {
		return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
	}
	if err := file.Chmod(0o400); err != nil {
		return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
	}
	success = true
	return nil
}

func writeMetadata(root *os.Root, metadata identity.Metadata) error {
	encoded, err := json.Marshal(metadata)
	if err != nil || len(encoded) > maxMetadataBytes {
		return ErrArtifactIntegrity
	}
	file, err := secureCreate(root, identity.MetadataFile, 0o600)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
	}
	defer file.Close()
	if _, err := file.Write(encoded); err != nil {
		return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
	}
	if err := file.Sync(); err != nil {
		return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
	}
	if err := file.Chmod(0o400); err != nil {
		return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
	}
	return nil
}

func sameOrigin(candidate, expected *url.URL) bool {
	return candidate != nil &&
		expected != nil &&
		candidate.Scheme == expected.Scheme &&
		candidate.Host == expected.Host
}
