package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func parseModelCatalogPath(p string) (string, bool) {
	rest := strings.TrimPrefix(p, "/v1/models/catalog/")
	if rest == p || rest == "" {
		return "", false
	}
	modelID, err := url.PathUnescape(rest)
	if err != nil {
		return "", false
	}
	return modelID, true
}

func parseModelCatalogManifestPath(p string) (string, bool) {
	rest := strings.TrimPrefix(p, "/v1/models/catalog/manifest/")
	if rest == p || rest == "" {
		return "", false
	}
	modelID, err := url.PathUnescape(rest)
	if err != nil {
		return "", false
	}
	return modelID, true
}

func parseAdminModelActionPath(p string) (string, string, bool) {
	rest := strings.TrimPrefix(p, "/v1/admin/models/")
	if rest == p || rest == "" {
		return "", "", false
	}
	for _, action := range []string{"/promote", "/status", "/runtime-parameters", "/capabilities", "/deprecation", "/openrouter-slug"} {
		if strings.HasSuffix(rest, action) {
			modelID, err := url.PathUnescape(strings.TrimSuffix(rest, action))
			if err != nil {
				return "", "", false
			}
			return modelID, strings.TrimPrefix(action, "/"), true
		}
	}
	return "", "", false
}

func fetchModelManifest(ctx context.Context, baseURL, r2Prefix string) (*store.ModelManifest, error) {
	manifestURL, err := url.JoinPath(baseURL, r2Prefix, "manifest.json")
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, manifestURL, nil)
	if err != nil {
		return nil, err
	}
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("manifest GET returned %s", resp.Status)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 10<<20))
	if err != nil {
		return nil, err
	}
	var manifest store.ModelManifest
	if err := json.Unmarshal(body, &manifest); err != nil {
		return nil, err
	}
	return &manifest, nil
}

func verifyManifestFiles(ctx context.Context, baseURL string, manifest *store.ModelManifest, logger interface{ Warn(string, ...any) }) error {
	client := &http.Client{Timeout: 30 * time.Second}
	errCh := make(chan error, len(manifest.Files))
	fileCh := make(chan store.ManifestFile)
	var wg sync.WaitGroup
	workers := 8
	if len(manifest.Files) < workers {
		workers = len(manifest.Files)
	}
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for file := range fileCh {
				if err := verifyManifestFileHEAD(ctx, client, baseURL, manifest.R2Prefix, file, logger); err != nil {
					errCh <- err
				}
			}
		}()
	}
	for _, file := range manifest.Files {
		select {
		case fileCh <- file:
		case <-ctx.Done():
			close(fileCh)
			wg.Wait()
			close(errCh)
			return ctx.Err()
		}
	}
	close(fileCh)
	wg.Wait()
	close(errCh)
	for err := range errCh {
		if err != nil {
			return err
		}
	}
	return nil
}

func verifyManifestFileHEAD(ctx context.Context, client *http.Client, baseURL, r2Prefix string, file store.ManifestFile, logger interface{ Warn(string, ...any) }) error {
	fileURL, err := url.JoinPath(baseURL, r2Prefix, file.Path)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, fileURL, nil)
	if err != nil {
		return err
	}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("HEAD %s: %w", file.Path, err)
	}
	resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("HEAD %s returned %s", file.Path, resp.Status)
	}
	if resp.ContentLength >= 0 && resp.ContentLength != file.SizeBytes {
		return fmt.Errorf("HEAD %s content length %d != manifest size %d", file.Path, resp.ContentLength, file.SizeBytes)
	}
	if resp.ContentLength < 0 && logger != nil {
		logger.Warn("model registry: HEAD missing Content-Length", "path", file.Path)
	}
	return nil
}
