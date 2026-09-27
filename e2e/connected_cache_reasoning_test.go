package e2e

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestConnectedReasoningAliasesRepresentOneDelta(t *testing.T) {
	for _, test := range []struct {
		name  string
		delta string
		want  string
	}{
		{"reasoning_content", `{"reasoning_content":"one delta"}`, "one delta"},
		{"reasoning", `{"reasoning":"one delta"}`, "one delta"},
		{"matching aliases", `{"reasoning_content":"one delta","reasoning":"one delta"}`, "one delta"},
		{"empty aliases", `{"reasoning_content":"","reasoning":""}`, ""},
		{"absent aliases", `{}`, ""},
		{"null alias", `{"reasoning_content":null,"reasoning":"one delta"}`, "one delta"},
	} {
		t.Run(test.name, func(t *testing.T) {
			var out connectedStream
			content, err := out.acceptSSE([]byte(`data: {"choices":[{"delta":` + test.delta + `}]}`))
			require.NoError(t, err)
			require.Equal(t, test.want, out.Reasoning)
			require.Equal(t, test.want != "", content)
		})
	}
}

func TestConnectedReasoningAliasesRejectConflict(t *testing.T) {
	for _, delta := range []string{
		`{"reasoning_content":"first","reasoning":"different"}`,
		`{"reasoning_content":"","reasoning":"nonempty"}`,
		`{"reasoning_content":"nonempty","reasoning":""}`,
	} {
		t.Run(delta, func(t *testing.T) {
			out := connectedStream{Reasoning: "previous delta"}
			_, err := out.acceptSSE([]byte(`data: {"choices":[{"delta":` + delta + `}]}`))
			require.ErrorContains(t, err, "conflicting SSE reasoning aliases")
			require.Equal(t, "previous delta", out.Reasoning)
		})
	}
}

func TestConnectedReasoningRawReplayIgnoresChunkBoundaries(t *testing.T) {
	// These are the original HTTP bytes from the failed real Q38 donor/repeat
	// pair. Identical reasoning arrived in 19 and 17 chunks. Appending both
	// aliases interleaves duplicated fragments differently and invents a mismatch.
	data, err := os.ReadFile("testdata/connected_reasoning_aliases.json")
	require.NoError(t, err)
	var fixture struct {
		SourceReportSHA256 string `json:"source_report_sha256"`
		ExpectedReasoning  string `json:"expected_reasoning"`
		Cases              []struct {
			Name            string `json:"name"`
			RawSSE          string `json:"raw_sse"`
			DualAliasChunks int    `json:"dual_alias_chunks"`
		} `json:"cases"`
	}
	require.NoError(t, json.Unmarshal(data, &fixture))
	require.Equal(t, "dd1b4b6ec61e29296696e26231d4555e28d52a52dc65dfd829856ec756b40663", fixture.SourceReportSHA256)
	require.Len(t, fixture.Cases, 2)
	require.NotEmpty(t, fixture.ExpectedReasoning)
	require.Equal(t, 19, fixture.Cases[0].DualAliasChunks)
	require.Equal(t, 17, fixture.Cases[1].DualAliasChunks)
	for _, test := range fixture.Cases {
		t.Run(test.Name, func(t *testing.T) {
			require.Equal(t, test.DualAliasChunks, strings.Count(test.RawSSE, `"reasoning_content"`))
			var out connectedStream
			for _, line := range strings.Split(test.RawSSE, "\n") {
				_, err := out.acceptSSE([]byte(line))
				require.NoError(t, err)
			}
			require.True(t, out.Done)
			require.Equal(t, "length", out.Finish)
			require.Empty(t, out.Content)
			require.Equal(t, fixture.ExpectedReasoning, out.Reasoning)
		})
	}
}
