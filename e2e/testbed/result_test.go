package testbed

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestLoadGeneratorReturnsThresholdAndCohortFailures(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request struct {
			Model string `json:"model"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Errorf("decode request body: %v", err)
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if requests.Add(1) == 2 {
			http.Error(w, "provider unavailable", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprintf(w, `{"model":%q,"choices":[{"message":{"content":"ok"}}]}`, request.Model)
	}))
	t.Cleanup(server.Close)

	result, err := NewLoadGenerator(loadTestSuite(server.URL, []string{"model-a", "model-b"}, 2), RequestConfig{
		MaxTokens:         8,
		Streaming:         false,
		Concurrency:       1,
		TotalRequests:     4,
		ExpectedSuccesses: 4,
		MinimumSuccesses:  4,
	}).Run()

	require.Error(t, err)
	assert.ErrorContains(t, err, "got 3 successes, expected 4, minimum 4")
	assert.ErrorContains(t, err, "status 503: provider unavailable")
	assert.Equal(t, 3, result.SuccessCount)
	assert.Equal(t, 1, result.ErrorCount)
	require.Len(t, result.Failures, 1)
	assert.ErrorContains(t, result.Failures[0], "status 503: provider unavailable")

	require.Len(t, result.ModelCohorts, 2)
	assert.Equal(t, 2, result.ModelCohorts["model-a"].TotalRequests)
	assert.Equal(t, 2, result.ModelCohorts["model-b"].TotalRequests)
	assert.Equal(t, 1, result.ModelCohorts["model-b"].ErrorCount)
	require.Len(t, result.UserCohorts, 2)
	assert.Equal(t, 2, result.UserCohorts[0].TotalRequests)
	assert.Equal(t, 2, result.UserCohorts[1].TotalRequests)
	assert.Equal(t, 1, result.UserCohorts[1].ErrorCount)
}
