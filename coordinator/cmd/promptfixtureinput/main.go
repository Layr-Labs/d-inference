// Command promptfixtureinput snapshots the public manifest-backed production
// catalog and provisions only its prompt artifacts for the cross-language
// parity generator. The serving sidecar itself remains network-isolated.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

const (
	maxCatalogBytes  = 4 << 20
	maxManifestBytes = 1 << 20
	maxModels        = 128
)

type catalogResponse struct {
	Models []catalogModel `json:"models"`
}

type catalogModel struct {
	ID string `json:"id"`
}

type catalogManifest struct {
	SchemaVersion   int                       `json:"schema_version"`
	ModelID         string                    `json:"model_id"`
	R2Prefix        string                    `json:"r2_prefix"`
	AggregateSHA256 string                    `json:"aggregate_sha256"`
	Files           []promptcontract.Artifact `json:"files"`
}

func main() {
	var (
		catalogURL   = flag.String("catalog-url", "", "public /v1/models/catalog URL")
		cdnURL       = flag.String("cdn-url", "https://models.darkbloom.ai", "immutable model artifact CDN")
		artifactRoot = flag.String("artifact-root", "", "prompt artifact cache root")
		manifestDir  = flag.String("manifest-directory", "", "empty output directory for active manifests")
		manifestSrc  = flag.String("manifest-source-directory", "", "checked-in immutable manifest directory")
	)
	flag.Parse()
	if *artifactRoot == "" || *manifestDir == "" || (*catalogURL == "") == (*manifestSrc == "") {
		fatal(errors.New("artifact-root, manifest-directory, and exactly one manifest source are required"))
	}
	cdn, err := parseHTTPSURL(*cdnURL)
	if err != nil {
		fatal(fmt.Errorf("CDN URL: %w", err))
	}
	if err := prepareEmptyDirectory(*manifestDir); err != nil {
		fatal(err)
	}
	cache, err := promptcontract.NewArtifactCache(promptcontract.ArtifactCacheConfig{
		Root:            *artifactRoot,
		BaseURL:         cdn,
		DownloadTimeout: 2 * time.Minute,
	})
	if err != nil {
		fatal(err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if *manifestSrc != "" {
		count, err := provisionSnapshotManifests(ctx, *manifestSrc, *manifestDir, cache)
		if err != nil {
			fatal(err)
		}
		fmt.Printf("provisioned %d immutable prompt manifests\n", count)
		return
	}
	catalog, err := parseHTTPSURL(*catalogURL)
	if err != nil {
		fatal(fmt.Errorf("catalog URL: %w", err))
	}
	client := &http.Client{Timeout: 30 * time.Second}
	var catalogBody catalogResponse
	if _, err := fetchJSON(ctx, client, catalog, maxCatalogBytes, &catalogBody); err != nil {
		fatal(fmt.Errorf("fetch production catalog: %w", err))
	}
	modelIDs, err := validatedModelIDs(catalogBody.Models)
	if err != nil {
		fatal(err)
	}
	for _, modelID := range modelIDs {
		manifestURL := manifestURL(catalog, modelID)
		var manifest catalogManifest
		encoded, err := fetchJSON(ctx, client, manifestURL, maxManifestBytes, &manifest)
		if err != nil {
			fatal(fmt.Errorf("fetch manifest for %q: %w", modelID, err))
		}
		if manifest.SchemaVersion != 1 || manifest.ModelID != modelID {
			fatal(fmt.Errorf("manifest identity mismatch for %q", modelID))
		}
		if _, err := cache.Ensure(ctx, promptcontract.Manifest{
			ModelID:         manifest.ModelID,
			R2Prefix:        manifest.R2Prefix,
			AggregateSHA256: manifest.AggregateSHA256,
			Files:           manifest.Files,
		}); err != nil {
			fatal(fmt.Errorf("provision prompt artifacts for %q: %w", modelID, err))
		}
		nameDigest := sha256.Sum256([]byte(modelID))
		output := filepath.Join(*manifestDir, hex.EncodeToString(nameDigest[:])+".json")
		if err := os.WriteFile(output, encoded, 0o600); err != nil {
			fatal(fmt.Errorf("write manifest for %q: %w", modelID, err))
		}
	}
	fmt.Printf("provisioned %d production prompt manifests\n", len(modelIDs))
}

func provisionSnapshotManifests(
	ctx context.Context,
	sourceDirectory, outputDirectory string,
	cache *promptcontract.ArtifactCache,
) (int, error) {
	entries, err := os.ReadDir(sourceDirectory)
	if err != nil {
		return 0, fmt.Errorf("read immutable manifest directory: %w", err)
	}
	if len(entries) == 0 || len(entries) > maxModels {
		return 0, errors.New("immutable manifest directory is empty or exceeds its model bound")
	}
	seenModels := make(map[string]bool, len(entries))
	count := 0
	for _, entry := range entries {
		if entry.IsDir() || entry.Type()&os.ModeSymlink != 0 ||
			filepath.Ext(entry.Name()) != ".json" {
			return 0, fmt.Errorf("invalid immutable manifest entry %q", entry.Name())
		}
		info, err := entry.Info()
		if err != nil || !info.Mode().IsRegular() || info.Size() > maxManifestBytes {
			return 0, fmt.Errorf("unsafe immutable manifest entry %q", entry.Name())
		}
		encoded, err := os.ReadFile(filepath.Join(sourceDirectory, entry.Name()))
		if err != nil {
			return 0, fmt.Errorf("read immutable manifest %q: %w", entry.Name(), err)
		}
		var manifest catalogManifest
		if err := decodeJSON(encoded, &manifest); err != nil {
			return 0, fmt.Errorf("decode immutable manifest %q: %w", entry.Name(), err)
		}
		if manifest.SchemaVersion != 1 || manifest.ModelID == "" ||
			strings.ContainsRune(manifest.ModelID, '\x00') || seenModels[manifest.ModelID] {
			return 0, fmt.Errorf("invalid immutable manifest identity in %q", entry.Name())
		}
		seenModels[manifest.ModelID] = true
		if _, err := cache.Ensure(ctx, promptcontract.Manifest{
			ModelID:         manifest.ModelID,
			R2Prefix:        manifest.R2Prefix,
			AggregateSHA256: manifest.AggregateSHA256,
			Files:           manifest.Files,
		}); err != nil {
			return 0, fmt.Errorf("provision prompt artifacts for %q: %w", manifest.ModelID, err)
		}
		nameDigest := sha256.Sum256([]byte(manifest.ModelID))
		output := filepath.Join(outputDirectory, hex.EncodeToString(nameDigest[:])+".json")
		if err := os.WriteFile(output, encoded, 0o600); err != nil {
			return 0, fmt.Errorf("write manifest for %q: %w", manifest.ModelID, err)
		}
		count++
	}
	return count, nil
}

func fetchJSON(
	ctx context.Context,
	client *http.Client,
	target *url.URL,
	limit int64,
	output any,
) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, target.String(), nil)
	if err != nil {
		return nil, err
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", response.StatusCode)
	}
	encoded, err := io.ReadAll(io.LimitReader(response.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(encoded)) > limit {
		return nil, errors.New("response exceeded size bound")
	}
	if err := decodeJSON(encoded, output); err != nil {
		return nil, err
	}
	return encoded, nil
}

func decodeJSON(encoded []byte, output any) error {
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	if err := decoder.Decode(output); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("response contained trailing JSON")
	}
	return nil
}

func validatedModelIDs(models []catalogModel) ([]string, error) {
	if len(models) == 0 || len(models) > maxModels {
		return nil, errors.New("production catalog is empty or exceeds its model bound")
	}
	seen := make(map[string]bool, len(models))
	ids := make([]string, 0, len(models))
	for _, model := range models {
		if model.ID == "" || seen[model.ID] || strings.ContainsRune(model.ID, '\x00') {
			return nil, errors.New("production catalog contains an invalid or duplicate model ID")
		}
		seen[model.ID] = true
		ids = append(ids, model.ID)
	}
	sort.Strings(ids)
	return ids, nil
}

func manifestURL(catalog *url.URL, modelID string) *url.URL {
	target := *catalog
	parts := strings.Split(modelID, "/")
	for index := range parts {
		parts[index] = url.PathEscape(parts[index])
	}
	target.Path = strings.TrimSuffix(catalog.Path, "/") + "/manifest/" + strings.Join(parts, "/")
	target.RawPath = ""
	target.RawQuery = ""
	target.Fragment = ""
	return &target
}

func parseHTTPSURL(raw string) (*url.URL, error) {
	parsed, err := url.Parse(raw)
	if err != nil {
		return nil, err
	}
	if parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil ||
		parsed.RawQuery != "" || parsed.Fragment != "" {
		return nil, errors.New("URL must be an uncredentialed HTTPS origin/path")
	}
	return parsed, nil
}

func prepareEmptyDirectory(directory string) error {
	if directory == "" || !filepath.IsAbs(directory) {
		return errors.New("manifest directory must be absolute")
	}
	if err := os.Mkdir(directory, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
		return err
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		return err
	}
	if len(entries) != 0 {
		return errors.New("manifest directory must be empty")
	}
	return nil
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
