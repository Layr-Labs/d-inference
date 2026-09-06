package e2e

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"testing"
)

// Opt-in seven-request scope across four separately owned model runs.
func TestIntegrationReleaseCapabilitiesHTTP(t *testing.T) {
	runReleaseDefaultHTTP(t, true)
}

func releaseCapabilityCases(in connectedCacheInput) ([]connectedCase, error) {
	vision := false
	switch in.Artifact.ModelID {
	case "qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8", "gemma-4-26b-qat-4bit":
		vision = true
	case "gpt-oss-20b":
	default:
		return nil, fmt.Errorf("capabilities scope requires an exact remaining release target")
	}
	if vision != (in.VisionPNG != "") || vision != (in.VisionSHA256 != "") {
		return nil, fmt.Errorf("exact supported vision fixture required; no silent omission")
	}
	var tools map[string]any
	if err := json.Unmarshal(in.ToolsRequest, &tools); err != nil {
		return nil, err
	}
	if len(tools) == 0 {
		return nil, fmt.Errorf("original tools request required")
	}
	tools["model"] = in.Artifact.ModelID
	tools["stream"] = true
	tools["stream_options"] = map[string]bool{"include_usage": true}
	body, err := json.Marshal(tools)
	if err != nil {
		return nil, err
	}
	rows := []connectedCase{{Name: "tools", Status: "not_run", Request: body}}
	if !vision {
		return rows, nil
	}
	hash, err := fileSHA256(in.VisionPNG)
	if err != nil {
		return nil, err
	}
	if hash != in.VisionSHA256 {
		return nil, fmt.Errorf("vision fixture hash differs")
	}
	image, err := os.ReadFile(in.VisionPNG)
	if err != nil {
		return nil, err
	}
	request := map[string]any{"model": in.Artifact.ModelID, "messages": []any{map[string]any{"role": "user", "content": []any{map[string]any{"type": "text", "text": "Describe the visible colors and shape in one short sentence."}, map[string]any{"type": "image_url", "image_url": map[string]string{"url": "data:image/png;base64," + base64.StdEncoding.EncodeToString(image)}}}}}, "temperature": 0, "max_tokens": 64, "stream": true, "stream_options": map[string]bool{"include_usage": true}}
	body, err = json.Marshal(request)
	if err != nil {
		return nil, err
	}
	return append(rows, connectedCase{Name: "vision", Status: "not_run", Request: body}), nil
}
