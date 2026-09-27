package e2e

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestConnectedRouteLoggerPreservesStartupDiagnostics(t *testing.T) {
	var output bytes.Buffer
	routes := &connectedRouteLog{}
	logger := slog.New(&connectedRouteHandler{
		routes: routes,
		output: slog.NewJSONHandler(&output, &slog.HandlerOptions{Level: slog.LevelInfo}),
	})
	logger.With("provider_index", 1).WithGroup("startup").Error("provider:stderr", "line", "registration failed")
	var record map[string]any
	require.NoError(t, json.Unmarshal(output.Bytes(), &record))
	require.Equal(t, "provider:stderr", record["msg"])
	require.Equal(t, float64(1), record["provider_index"])
	require.Equal(t, map[string]any{"line": "registration failed"}, record["startup"])
	require.Empty(t, routes.snapshot(), "startup diagnostics must not become routing evidence")

	output.Reset()
	logger.Debug("routing_decision", "provider_id", "provider-1")
	require.Empty(t, output.String(), "preserve the testbed output level")
	rows := routes.snapshot()
	require.Len(t, rows, 1, "debug routing observations must still be collected")
	require.Equal(t, "provider-1", rows[0]["provider_id"])
}
