package inferencefixture

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/catalog"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	Alias         = "bench-alias"
	DesiredBuild  = "bench-build-desired"
	PreviousBuild = "bench-build-previous"
)

var BodyNames = []string{"small_2KB", "history_60KB", "history_tools_60KB", "image_3MB"}

// benchTurnText is ~1.4 KB of prose carrying the characters the forward
// marshal must handle (quotes, backslashes, newlines, HTML-significant bytes).
var turnText = strings.Repeat(
	`The quick "brown" fox <jumps> over the lazy dog & keeps running.\nIt said: `+
		`"don't stop" — then paused for 3.5 seconds before continuing east. `,
	10)

func chatMessage(role, text string) map[string]any {
	return map[string]any{"role": role, "content": text}
}

func tools() []any {
	tools := make([]any, 0, 6)
	for i := 0; i < 6; i++ {
		tools = append(tools, map[string]any{
			"type": "function",
			"function": map[string]any{
				"name":        fmt.Sprintf("lookup_%d", i),
				"description": "Look something up",
				"parameters": map[string]any{
					"type": "object",
					"properties": map[string]any{
						// Missing `type` and a nullable union: both are shapes the
						// coordinator-side normalizer repairs.
						"query":  map[string]any{"description": "search text"},
						"limit":  map[string]any{"type": []any{"integer", "null"}},
						"filter": map[string]any{"type": "string", "enum": []any{"a", "b"}},
					},
					"required": []any{"query"},
				},
			},
		})
	}
	return tools
}

// benchRequestBodies builds the request bodies keyed by benchBodyNames.
func RequestBodies() map[string][]byte {
	small := map[string]any{
		"model":  Alias,
		"stream": false,
		"messages": []any{
			chatMessage("system", "You are a concise assistant."),
			chatMessage("user", turnText),
		},
	}
	history := make([]any, 0, 42)
	history = append(history, chatMessage("system", "You are a concise assistant."))
	for i := 0; i < 40; i++ {
		role := "user"
		if i%2 == 1 {
			role = "assistant"
		}
		history = append(history, chatMessage(role, turnText))
	}
	history = append(history, chatMessage("user", "Summarize the conversation."))
	historyBody := map[string]any{"model": Alias, "stream": false, "messages": history}
	historyTools := map[string]any{
		"model": Alias, "stream": false, "messages": history,
		"tools": tools(), "tool_choice": "auto",
	}

	// ~2.25 MB of incompressible bytes → ~3 MB of base64 in a data: URI.
	rnd := rand.New(rand.NewPCG(7, 11))
	raw := make([]byte, 2_250_000)
	for i := 0; i+8 <= len(raw); i += 8 {
		v := rnd.Uint64()
		for j := 0; j < 8; j++ {
			raw[i+j] = byte(v >> (8 * j))
		}
	}
	image := map[string]any{
		"model": Alias, "stream": false, "max_tokens": 64,
		"messages": []any{map[string]any{"role": "user", "content": []any{
			map[string]any{"type": "text", "text": "Describe this image."},
			map[string]any{"type": "image_url", "image_url": map[string]any{
				"url": "data:image/png;base64," + base64.StdEncoding.EncodeToString(raw),
			}},
		}}},
	}

	bodies := make(map[string][]byte, 4)
	for name, v := range map[string]any{
		"small_2KB": small, "history_60KB": historyBody,
		"history_tools_60KB": historyTools, "image_3MB": image,
	} {
		b, err := json.Marshal(v)
		if err != nil {
			panic(err)
		}
		bodies[name] = b
	}
	return bodies
}

func SeedModel(tb testing.TB, st store.Store, model string, runtimeParameters map[string]any) {
	tb.Helper()
	entry := &store.ModelRegistryEntry{
		ID: model, DisplayName: model, Quantization: "4bit",
		MaxContextLength: 131072, MaxOutputLength: 8192, MinRAMGB: 24,
		Capabilities: []string{"chat", "vision"}, Status: "active",
		RuntimeParameters: runtimeParameters,
	}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, &store.ModelVersion{
		ModelID: model, Version: "v1", R2Prefix: catalog.ModelR2Prefix(model, "v1"),
		AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready",
	}, files); err != nil {
		tb.Fatal(err)
	}
	if err := st.PromoteModelVersion(model, "v1"); err != nil {
		tb.Fatal(err)
	}
}

const testHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
