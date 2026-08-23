package testbed

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestLoadGeneratorRequiresSuccessCounts(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		t.Fatal("invalid load configuration dispatched a request")
	}))
	t.Cleanup(server.Close)

	result, err := NewLoadGenerator(loadTestSuite(server.URL, []string{"model-a"}, 1), RequestConfig{
		Concurrency:   1,
		TotalRequests: 1,
	}).Run()

	require.Error(t, err)
	assert.ErrorContains(t, err, "expected successes must be positive")
	assert.Zero(t, result.SuccessCount)
}

func loadTestSuite(baseURL string, models []string, userCount int) *Suite {
	users := make([]UserAccount, userCount)
	for i := range userCount {
		users[i] = UserAccount{
			AccountID: fmt.Sprintf("account-%d", i),
			APIKey:    fmt.Sprintf("key-%d", i),
		}
	}
	return &Suite{
		Ctx:         context.Background(),
		Coordinator: &Coordinator{baseURL: strings.TrimSuffix(baseURL, "/")},
		Config: SuiteConfig{ModelSpecs: []ModelSpec{{
			ModelIDs:     append([]string(nil), models...),
			NumProviders: 1,
		}}},
		Users: users,
	}
}
