package promptcontract

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path"
	"slices"
	"strings"
	"sync"
	"time"
)

const (
	DefaultArtifactRoot    = "/data/prompt-contracts"
	maxMetadataBytes       = 1 << 20
	maxArtifactBytes       = 128 << 20
	maxContractBytes       = 512 << 20
	defaultDownloadTimeout = 2 * time.Minute
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
		downloadTimeout = defaultDownloadTimeout
	}
	return &ArtifactCache{
		root:            root,
		baseURL:         config.BaseURL,
		httpClient:      client,
		downloadTimeout: downloadTimeout,
		inflight:        make(map[string]*artifactCall),
	}, nil
}

func (c *ArtifactCache) Ensure(ctx context.Context, manifest Manifest) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, c.downloadTimeout)
	defer cancel()
	artifacts, err := PromptArtifacts(manifest.Files)
	if err != nil {
		return "", err
	}
	contractID, err := ContractID(artifacts, CurrentVersions())
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

func (c *ArtifactCache) ensureOne(ctx context.Context, manifest Manifest, artifacts []Artifact, contractID string) (string, error) {
	if !validRelativePath(manifest.R2Prefix) {
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
	if ok, err := verifyPublished(root, contractID); ok {
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
			_ = makeTreeWritable(tempRoot)
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
	metadata := Metadata{
		SchemaVersion:        1,
		PromptContractID:     contractID,
		ModelID:              manifest.ModelID,
		ModelType:            manifest.ModelType,
		ModelAggregateSHA256: manifest.AggregateSHA256,
		Artifacts:            slices.Clone(artifacts),
		Versions:             CurrentVersions(),
	}
	slices.SortFunc(metadata.Artifacts, func(a, b Artifact) int {
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
		if ok, verifyErr := verifyPublished(root, contractID); ok {
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

func (c *ArtifactCache) downloadArtifact(ctx context.Context, root *os.Root, prefix string, artifact Artifact) error {
	if !validRelativePath(artifact.Path) {
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
	expected, err := parseDigest(artifact.SHA256)
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

func writeMetadata(root *os.Root, metadata Metadata) error {
	encoded, err := json.Marshal(metadata)
	if err != nil || len(encoded) > maxMetadataBytes {
		return ErrArtifactIntegrity
	}
	file, err := secureCreate(root, MetadataFile, 0o600)
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

func verifyPublished(root *os.Root, contractID string) (bool, error) {
	info, err := root.Lstat(contractID)
	if err != nil {
		return false, err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return false, ErrArtifactIntegrity
	}
	contractDirectory, err := secureOpenDirectory(root, contractID, false, 0)
	if err != nil {
		return false, ErrArtifactIntegrity
	}
	defer contractDirectory.Close()
	file, err := secureOpenRegular(root, path.Join(contractID, MetadataFile))
	if err != nil {
		return false, ErrArtifactIntegrity
	}
	defer file.Close()
	metadataInfo, err := file.Stat()
	if err != nil || metadataInfo.Size() > maxMetadataBytes {
		return false, ErrArtifactIntegrity
	}
	encoded, err := io.ReadAll(io.LimitReader(file, maxMetadataBytes+1))
	if err != nil || len(encoded) > maxMetadataBytes {
		return false, ErrArtifactIntegrity
	}
	var metadata Metadata
	if json.Unmarshal(encoded, &metadata) != nil ||
		metadata.SchemaVersion != 1 ||
		metadata.PromptContractID != contractID ||
		metadata.Versions != CurrentVersions() {
		return false, ErrArtifactIntegrity
	}
	recomputed, err := ContractID(metadata.Artifacts, metadata.Versions)
	if err != nil || recomputed != contractID {
		return false, ErrArtifactIntegrity
	}
	for _, artifact := range metadata.Artifacts {
		if err := verifyPublishedArtifact(root, contractID, artifact); err != nil {
			return false, err
		}
	}
	return true, nil
}

func verifyPublishedArtifact(root *os.Root, contractID string, artifact Artifact) error {
	if !IsPromptRole(artifact.Role) ||
		!validRelativePath(artifact.Path) ||
		artifact.SizeBytes < 0 ||
		artifact.SizeBytes > maxArtifactBytes {
		return ErrArtifactIntegrity
	}
	file, err := secureOpenRegular(root, path.Join(contractID, artifact.Path))
	if err != nil {
		return ErrArtifactIntegrity
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || info.Size() != artifact.SizeBytes {
		return ErrArtifactIntegrity
	}
	hasher := sha256.New()
	written, err := io.Copy(hasher, io.LimitReader(file, artifact.SizeBytes+1))
	if err != nil || written != artifact.SizeBytes {
		return ErrArtifactIntegrity
	}
	expected, err := parseDigest(artifact.SHA256)
	if err != nil || !equalBytes(hasher.Sum(nil), expected) {
		return ErrArtifactIntegrity
	}
	return nil
}

func verifyManifestAggregate(manifest Manifest) error {
	if manifest.ModelID == "" || !validRelativePath(manifest.R2Prefix) {
		return ErrArtifactIntegrity
	}
	files := slices.Clone(manifest.Files)
	slices.SortFunc(files, func(a, b Artifact) int {
		if result := strings.Compare(a.Path, b.Path); result != 0 {
			return result
		}
		return strings.Compare(a.SHA256, b.SHA256)
	})
	hasher := sha256.New()
	for _, file := range files {
		if !validRelativePath(file.Path) || file.SizeBytes < 0 {
			return ErrArtifactIntegrity
		}
		digest, err := parseDigest(file.SHA256)
		if err != nil {
			return ErrArtifactIntegrity
		}
		_, _ = hasher.Write(digest)
	}
	expected, err := parseDigest(manifest.AggregateSHA256)
	if err != nil || !equalBytes(hasher.Sum(nil), expected) {
		return ErrArtifactIntegrity
	}
	return nil
}

func makeTreeContentsReadOnly(root *os.Root) error {
	var directories []string
	if err := fs.WalkDir(root.FS(), ".", func(name string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return ErrArtifactIntegrity
		}
		if entry.IsDir() {
			directories = append(directories, name)
		}
		return nil
	}); err != nil {
		return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
	}
	slices.Reverse(directories)
	for _, name := range directories {
		if name == "." {
			continue
		}
		directory, err := secureOpenDirectory(root, name, false, 0)
		if err != nil {
			return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
		}
		if err := directory.Chmod(0o500); err != nil {
			_ = directory.Close()
			return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
		}
		if err := directory.Sync(); err != nil {
			_ = directory.Close()
			return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
		}
		if err := directory.Close(); err != nil {
			return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
		}
	}
	return rejectSymlinks(root)
}

func makeTreeWritable(root *os.Root) error {
	var directories []string
	if err := fs.WalkDir(root.FS(), ".", func(name string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			directories = append(directories, name)
		}
		return nil
	}); err != nil {
		return err
	}
	for _, name := range directories {
		directory, err := secureOpenDirectory(root, name, false, 0)
		if err != nil {
			return err
		}
		if err := directory.Chmod(0o700); err != nil {
			_ = directory.Close()
			return err
		}
		if err := directory.Close(); err != nil {
			return err
		}
	}
	return nil
}

func rejectSymlinks(root *os.Root) error {
	return fs.WalkDir(root.FS(), ".", func(_ string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return ErrArtifactIntegrity
		}
		return nil
	})
}

func syncRoot(root *os.Root) error {
	directory, err := root.Open(".")
	if err != nil {
		return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
	}
	defer directory.Close()
	if err := directory.Sync(); err != nil {
		return fmt.Errorf("%w: %v", ErrArtifactUnavailable, err)
	}
	return nil
}

func randomTempName(contractID string) (string, error) {
	var suffix [16]byte
	if _, err := rand.Read(suffix[:]); err != nil {
		return "", err
	}
	return ".tmp-" + contractID[:12] + "-" + hex.EncodeToString(suffix[:]), nil
}

func equalBytes(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	var mismatch byte
	for i := range a {
		mismatch |= a[i] ^ b[i]
	}
	return mismatch == 0
}

func pathIsAbsoluteClean(value string) bool {
	return strings.HasPrefix(value, "/") && path.Clean(value) == value
}

func sameOrigin(candidate, expected *url.URL) bool {
	return candidate != nil &&
		expected != nil &&
		candidate.Scheme == expected.Scheme &&
		candidate.Host == expected.Host
}
