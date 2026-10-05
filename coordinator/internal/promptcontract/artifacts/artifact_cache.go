package artifacts

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path"
	"slices"
	"strings"
	"sync"
	"time"

	identity "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/identity"
)

const (
	DefaultArtifactRoot    = "/mnt/disks/userdata/prompt-contracts"
	maxMetadataBytes       = 1 << 20
	maxArtifactBytes       = 128 << 20
	maxContractBytes       = 512 << 20
	DefaultDownloadTimeout = 2 * time.Minute
)

var (
	ErrArtifactUnavailable = errors.New("prompt-contract artifact unavailable")
	ErrArtifactIntegrity   = errors.New("prompt-contract artifact integrity failure")
	ErrUnsafeArtifactPath  = errors.New("unsafe prompt-contract artifact path")
)

type ArtifactCacheConfig struct {
	Root            string
	BaseURL         *url.URL
	HTTPClient      *http.Client
	AllowHTTP       bool
	DownloadTimeout time.Duration
}

type ArtifactCache struct {
	root            string
	baseURL         *url.URL
	httpClient      *http.Client
	downloadTimeout time.Duration

	mu       sync.Mutex
	inflight map[string]*artifactCall
}

type artifactCall struct {
	done chan struct{}
	path string
	err  error
}

func NewArtifactCache(config ArtifactCacheConfig) (*ArtifactCache, error) {
	root := config.Root
	if root == "" {
		root = DefaultArtifactRoot
	}
	if !pathIsAbsoluteClean(root) {
		return nil, ErrUnsafeArtifactPath
	}
	if config.BaseURL == nil || config.BaseURL.Host == "" {
		return nil, ErrUnsafeArtifactPath
	}
	if config.BaseURL.Scheme != "https" && !(config.AllowHTTP && config.BaseURL.Scheme == "http") {
		return nil, ErrUnsafeArtifactPath
	}
	if config.BaseURL.User != nil || config.BaseURL.RawQuery != "" || config.BaseURL.Fragment != "" {
		return nil, ErrUnsafeArtifactPath
	}
	client := config.HTTPClient
	if client == nil {
		client = &http.Client{}
	}
	clientCopy := *client
	originalRedirectPolicy := client.CheckRedirect
	clientCopy.CheckRedirect = func(request *http.Request, via []*http.Request) error {
		if !sameOrigin(request.URL, config.BaseURL) {
			return ErrArtifactIntegrity
		}
		if originalRedirectPolicy != nil {
			return originalRedirectPolicy(request, via)
		}
		if len(via) >= 10 {
			return errors.New("stopped after 10 redirects")
		}
		return nil
	}
	client = &clientCopy
	downloadTimeout := config.DownloadTimeout
	if downloadTimeout <= 0 {
		downloadTimeout = DefaultDownloadTimeout
	}
	return &ArtifactCache{
		root:            root,
		baseURL:         config.BaseURL,
		httpClient:      client,
		downloadTimeout: downloadTimeout,
		inflight:        make(map[string]*artifactCall),
	}, nil
}

func (c *ArtifactCache) Ensure(ctx context.Context, manifest identity.Manifest) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, c.downloadTimeout)
	defer cancel()
	artifacts, err := identity.PromptArtifacts(manifest.Files)
	if err != nil {
		return "", err
	}
	contractID, err := identity.ContractID(artifacts, identity.CurrentVersions())
	if err != nil {
		return "", err
	}
	c.mu.Lock()
	if call := c.inflight[contractID]; call != nil {
		c.mu.Unlock()
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-call.done:
			return call.path, call.err
		}
	}
	call := &artifactCall{done: make(chan struct{})}
	c.inflight[contractID] = call
	c.mu.Unlock()

	call.path, call.err = c.ensureOne(ctx, manifest, artifacts, contractID)
	c.mu.Lock()
	delete(c.inflight, contractID)
	close(call.done)
	c.mu.Unlock()
	return call.path, call.err
}

func (c *ArtifactCache) ensureOne(ctx context.Context, manifest identity.Manifest, artifacts []identity.Artifact, contractID string) (string, error) {
	if !identity.ValidRelativePath(manifest.R2Prefix) {
		return "", ErrUnsafeArtifactPath
	}
	if err := verifyManifestAggregate(manifest); err != nil {
		return "", err
	}
	root, err := openVerifiedRoot(c.root, 0o700)
	if err != nil {
		if errors.Is(err, ErrUnsafeArtifactPath) {
			return "", err
		}
		return "", fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
	}
	defer root.Close()
	if ok, err := VerifyPublished(root, contractID); ok {
		return path.Join(c.root, contractID), nil
	} else if err != nil && !errors.Is(err, fs.ErrNotExist) && !os.IsNotExist(err) {
		return "", err
	}

	tempName, err := randomTempName(contractID)
	if err != nil {
		return "", fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
	}
	if err := root.Mkdir(tempName, 0o700); err != nil {
		return "", fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
	}
	tempRoot, err := root.OpenRoot(tempName)
	if err != nil {
		_ = root.RemoveAll(tempName)
		return "", fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
	}
	defer tempRoot.Close()
	published := false
	cleanupName := tempName
	defer func() {
		if !published {
			_ = MakeTreeWritable(tempRoot)
			_ = root.RemoveAll(cleanupName)
		}
	}()

	var total int64
	for _, artifact := range artifacts {
		if artifact.SizeBytes > maxArtifactBytes || artifact.SizeBytes > maxContractBytes-total {
			return "", ErrArtifactIntegrity
		}
		total += artifact.SizeBytes
		if err := c.downloadArtifact(ctx, tempRoot, manifest.R2Prefix, artifact); err != nil {
			return "", err
		}
	}
	metadata := identity.Metadata{
		SchemaVersion:        1,
		PromptContractID:     contractID,
		ModelID:              manifest.ModelID,
		ModelType:            manifest.ModelType,
		ModelAggregateSHA256: manifest.AggregateSHA256,
		Artifacts:            slices.Clone(artifacts),
		Versions:             identity.CurrentVersions(),
	}
	slices.SortFunc(metadata.Artifacts, func(a, b identity.Artifact) int {
		return strings.Compare(a.Path, b.Path)
	})
	if err := writeMetadata(tempRoot, metadata); err != nil {
		return "", err
	}
	if err := syncRoot(tempRoot); err != nil {
		return "", err
	}
	if err := makeTreeContentsReadOnly(tempRoot); err != nil {
		return "", err
	}
	if err := renameRootEntry(root, c.root, tempName, contractID); err != nil {
		if ok, verifyErr := VerifyPublished(root, contractID); ok {
			_ = root.RemoveAll(tempName)
			published = true
			return path.Join(c.root, contractID), nil
		} else if verifyErr != nil &&
			!errors.Is(verifyErr, fs.ErrNotExist) &&
			!os.IsNotExist(verifyErr) {
			return "", verifyErr
		}
		return "", fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
	}
	cleanupName = contractID
	if err := tempRoot.Chmod(".", 0o500); err != nil {
		return "", fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
	}
	if err := syncRoot(tempRoot); err != nil {
		return "", err
	}
	if err := syncRoot(root); err != nil {
		return "", err
	}
	published = true
	return path.Join(c.root, contractID), nil
}

func randomTempName(contractID string) (string, error) {
	var suffix [16]byte
	if _, err := rand.Read(suffix[:]); err != nil {
		return "", err
	}
	return ".tmp-" + contractID[:12] + "-" + hex.EncodeToString(suffix[:]), nil
}

func pathIsAbsoluteClean(value string) bool {
	return strings.HasPrefix(value, "/") && path.Clean(value) == value
}
