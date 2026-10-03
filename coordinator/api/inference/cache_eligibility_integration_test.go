package inference

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
)

func cacheEligibilityV2Capability(modelID string) protocol.PrefixCacheV2Capability {
	return protocol.PrefixCacheV2Capability{
		ModelID:            modelID,
		ModelAggregateHash: strings.Repeat("a", 64),
		PromptContractID:   strings.Repeat("b", 64),
		BlockHashVersion:   promptcontract.BlockHashVersion,
		BlockSize:          promptcontract.BlockSize,
		CacheEpoch:         "11111111-1111-1111-1111-111111111111",
		Enabled:            true,
		Ready:              true,
	}
}

func writeProviderJSON(t *testing.T, ctx context.Context, conn *websocket.Conn, value any) {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatal(err)
	}
}

func waitCacheCondition(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("timed out waiting for cache telemetry state")
}
