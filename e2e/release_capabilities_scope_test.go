package e2e

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestReleaseCapabilityScopePreservesOriginalRequests(t *testing.T) {
	image := filepath.Join(t.TempDir(), "fixture.png")
	require.NoError(t, os.WriteFile(image, []byte("fixture bytes"), 0600))
	hash, err := fileSHA256(image)
	require.NoError(t, err)
	count := 0
	for _, model := range []string{"qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8", "gpt-oss-20b", "gemma-4-26b-qat-4bit"} {
		in := connectedCacheInput{ToolsRequest: json.RawMessage(`{"model":"original","messages":[{"role":"user","content":"original fixture"}],"tools":[{"type":"function","function":{"name":"record_color"}}],"tool_choice":"auto","max_tokens":512,"temperature":0}`)}
		in.Artifact.ModelID = model
		if model != "gpt-oss-20b" {
			in.VisionPNG, in.VisionSHA256 = image, hash
		}
		rows, err := releaseCapabilityCases(in)
		require.NoError(t, err)
		count += len(rows)
		require.Equal(t, "tools", rows[0].Name)
		var original, actual map[string]any
		require.NoError(t, json.Unmarshal(in.ToolsRequest, &original))
		require.NoError(t, json.Unmarshal(rows[0].Request, &actual))
		original["model"] = model
		original["stream"] = true
		original["stream_options"] = map[string]any{"include_usage": true}
		require.Equal(t, original, actual, "only model/stream envelope may change")
		if model == "gpt-oss-20b" {
			require.Len(t, rows, 1)
		} else {
			require.Len(t, rows, 2)
			require.Equal(t, "vision", rows[1].Name)
			require.NoError(t, json.Unmarshal(rows[1].Request, &actual))
			require.Equal(t, float64(64), actual["max_tokens"])
			require.Contains(t, string(rows[1].Request), "Describe the visible colors and shape in one short sentence.")
			require.Contains(t, string(rows[1].Request), "data:image/png;base64,Zml4dHVyZSBieXRlcw==")
			missing := in
			missing.VisionPNG = ""
			_, err = releaseCapabilityCases(missing)
			require.Error(t, err)
			wrong := in
			wrong.VisionSHA256 = "wrong"
			_, err = releaseCapabilityCases(wrong)
			require.Error(t, err)
		}
	}
	require.Equal(t, 7, count)
}

func TestReleaseCapabilityScopeRejectsExpandedOrMissingFixtures(t *testing.T) {
	for _, model := range []string{"EigenLabs/Qwen3.8-27B-4bit-mtp", "gemma-4-26b", "unknown"} {
		in := connectedCacheInput{ToolsRequest: json.RawMessage(`{}`)}
		in.Artifact.ModelID = model
		_, err := releaseCapabilityCases(in)
		require.Error(t, err)
	}
	for _, body := range []string{"", "null", "{}", "[]"} {
		in := connectedCacheInput{ToolsRequest: json.RawMessage(body)}
		in.Artifact.ModelID = "gpt-oss-20b"
		_, err := releaseCapabilityCases(in)
		require.Error(t, err)
	}
	in := connectedCacheInput{ToolsRequest: json.RawMessage(`{"messages":[]}`), VisionPNG: "unexpected", VisionSHA256: "unexpected"}
	in.Artifact.ModelID = "gpt-oss-20b"
	_, err := releaseCapabilityCases(in)
	require.Error(t, err)
}
