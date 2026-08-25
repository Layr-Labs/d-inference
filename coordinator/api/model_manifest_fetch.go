package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// A missing HEAD Content-Length is verified by counting a GET response only
// for reasonably small objects. Larger objects are rejected explicitly rather
// than turning registry publication into an unbounded multi-gigabyte read.
const maxUnknownLengthFileVerificationBytes int64 = 64 << 20

func fetchModelManifest(ctx context.Context, baseURL, r2Prefix string) (*store.ModelManifest, error) {
	manifestURL, err := url.JoinPath(baseURL, r2Prefix, "manifest.json")
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, manifestURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Accept-Encoding", "identity")

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("manifest GET returned %s", resp.Status)
	}
	body, err := readModelManifestBody(resp)
	if err != nil {
		return nil, err
	}
	var manifest store.ModelManifest
	if err := json.Unmarshal(body, &manifest); err != nil {
		return nil, err
	}
	return &manifest, nil
}

func readModelManifestBody(resp *http.Response) ([]byte, error) {
	if resp.ContentLength > maxModelManifestBytes {
		return nil, fmt.Errorf(
			"manifest response exceeds %d-byte limit (Content-Length %d)",
			maxModelManifestBytes,
			resp.ContentLength,
		)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxModelManifestBytes+1))
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > maxModelManifestBytes {
		return nil, fmt.Errorf("manifest response exceeds %d-byte limit", maxModelManifestBytes)
	}
	return body, nil
}

func verifyManifestFiles(
	ctx context.Context,
	baseURL string,
	manifest *store.ModelManifest,
	logger interface{ Warn(string, ...any) },
) error {
	if len(manifest.Files) == 0 {
		return fmt.Errorf("manifest contains no files")
	}

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
				if err := verifyManifestFileSize(ctx, client, baseURL, manifest.R2Prefix, file, logger); err != nil {
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

func verifyManifestFileSize(
	ctx context.Context,
	client *http.Client,
	baseURL, r2Prefix string,
	file store.ManifestFile,
	logger interface{ Warn(string, ...any) },
) error {
	fileURL, err := url.JoinPath(baseURL, r2Prefix, file.Path)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, fileURL, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept-Encoding", "identity")
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("HEAD %s: %w", file.Path, err)
	}
	resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("HEAD %s returned %s", file.Path, resp.Status)
	}
	if resp.ContentLength >= 0 {
		if resp.ContentLength != file.SizeBytes {
			return fmt.Errorf(
				"HEAD %s content length %d != manifest size %d",
				file.Path,
				resp.ContentLength,
				file.SizeBytes,
			)
		}
		return nil
	}

	if file.SizeBytes > maxUnknownLengthFileVerificationBytes {
		return fmt.Errorf(
			"HEAD %s omitted Content-Length and manifest size %d exceeds bounded GET verification limit %d",
			file.Path,
			file.SizeBytes,
			maxUnknownLengthFileVerificationBytes,
		)
	}
	if logger != nil {
		logger.Warn(
			"model registry: HEAD missing Content-Length; verifying with bounded GET",
			"path", file.Path,
			"maximum_bytes", maxUnknownLengthFileVerificationBytes,
		)
	}
	return verifyManifestFileWithBoundedGET(ctx, client, fileURL, file)
}

func verifyManifestFileWithBoundedGET(
	ctx context.Context,
	client *http.Client,
	fileURL string,
	file store.ManifestFile,
) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fileURL, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept-Encoding", "identity")
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("GET %s: %w", file.Path, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("GET %s returned %s", file.Path, resp.Status)
	}
	if resp.ContentLength >= 0 && resp.ContentLength != file.SizeBytes {
		return fmt.Errorf(
			"GET %s content length %d != manifest size %d",
			file.Path,
			resp.ContentLength,
			file.SizeBytes,
		)
	}

	// file.SizeBytes is nonnegative and at most the fixed fallback cap here,
	// so +1 cannot overflow. Reading one sentinel byte distinguishes exact
	// boundary responses from oversized chunked responses.
	actual, err := io.Copy(io.Discard, io.LimitReader(resp.Body, file.SizeBytes+1))
	if err != nil {
		return fmt.Errorf("GET %s body: %w", file.Path, err)
	}
	if actual != file.SizeBytes {
		return fmt.Errorf("GET %s body size %d != manifest size %d", file.Path, actual, file.SizeBytes)
	}
	return nil
}
