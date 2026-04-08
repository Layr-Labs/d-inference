package buildattest

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

const gitHubAPIBase = "https://api.github.com"

// AttestationResponse is the GitHub API response for listing attestations.
type AttestationResponse struct {
	Attestations []AttestationEntry `json:"attestations"`
}

// AttestationEntry is a single attestation from the GitHub API.
type AttestationEntry struct {
	Bundle json.RawMessage `json:"bundle"`
	// Note: The GitHub API also returns repository_id in the attestation,
	// but the bundle itself contains the cryptographically signed claims.
}

// httpClient is an interface for testing.
type httpClient interface {
	Do(req *http.Request) (*http.Response, error)
}

var defaultClient httpClient = &http.Client{Timeout: 30 * time.Second}

// FetchAttestations retrieves attestations for a given artifact digest from GitHub.
// The digest should be a hex-encoded SHA-256 hash (without the "sha256:" prefix).
func FetchAttestations(ctx context.Context, owner, repo, digest, token string) (*AttestationResponse, error) {
	return fetchAttestationsWithClient(ctx, defaultClient, gitHubAPIBase, owner, repo, digest, token)
}

func fetchAttestationsWithClient(ctx context.Context, client httpClient, baseURL, owner, repo, digest, token string) (*AttestationResponse, error) {
	url := fmt.Sprintf("%s/repos/%s/%s/attestations/sha256:%s", baseURL, owner, repo, digest)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("creating request: %w", err)
	}

	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("calling GitHub API: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 10<<20)) // 10 MB limit
	if err != nil {
		return nil, fmt.Errorf("reading response: %w", err)
	}

	switch resp.StatusCode {
	case http.StatusOK:
		// success
	case http.StatusNotFound:
		return &AttestationResponse{}, nil // no attestations
	case http.StatusTooManyRequests:
		return nil, fmt.Errorf("GitHub API rate limited (429)")
	default:
		return nil, fmt.Errorf("GitHub API returned %d: %s", resp.StatusCode, string(body))
	}

	var result AttestationResponse
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("decoding response: %w", err)
	}

	return &result, nil
}
