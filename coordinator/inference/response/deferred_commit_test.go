package response

import (
	"testing"
)

func TestIsBoilerplateChunk(t *testing.T) {
	cases := []struct {
		name  string
		chunk string
		want  bool
	}{
		{
			name:  "role-only delta with data prefix",
			chunk: `data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}`,
			want:  true,
		},
		{
			name:  "role-only delta without data prefix",
			chunk: `{"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}`,
			want:  true,
		},
		{
			name:  "role-only delta with trailing newlines",
			chunk: "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}\n\n",
			want:  true,
		},
		{
			name:  "role with empty content rides along",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}`,
			want:  true,
		},
		{
			name:  "role with null content rides along",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":null},"finish_reason":null}]}`,
			want:  true,
		},
		{
			name:  "role with empty tool_calls array rides along",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[]},"finish_reason":null}]}`,
			want:  true,
		},
		{
			name:  "role plus real content commits",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"},"finish_reason":null}]}`,
			want:  false,
		},
		{
			name:  "content-only delta commits",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}`,
			want:  false,
		},
		{
			name:  "role plus reasoning_content commits",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"thinking"},"finish_reason":null}]}`,
			want:  false,
		},
		{
			name:  "tool_calls delta commits",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"f","arguments":""}}]},"finish_reason":null}]}`,
			want:  false,
		},
		{
			name:  "finish chunk commits",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":"stop"}]}`,
			want:  false,
		},
		{
			name:  "usage-only chunk commits",
			chunk: `data: {"object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}`,
			want:  false,
		},
		{
			name:  "role delta carrying usage commits",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}],"usage":{"prompt_tokens":10,"completion_tokens":0,"total_tokens":10}}`,
			want:  false,
		},
		{
			name:  "null usage field is still boilerplate",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}],"usage":null}`,
			want:  true,
		},
		{
			name:  "done terminator commits",
			chunk: "data: [DONE]",
			want:  false,
		},
		{
			name:  "responses created event is boilerplate",
			chunk: `data: {"type":"response.created","response":{"id":"resp_1","object":"response","status":"in_progress"}}`,
			want:  true,
		},
		{
			name:  "responses in_progress event is boilerplate",
			chunk: `data: {"type":"response.in_progress","response":{"id":"resp_1","object":"response","status":"in_progress"}}`,
			want:  true,
		},
		{
			name:  "responses output_text delta commits",
			chunk: `data: {"type":"response.output_text.delta","delta":"Hello"}`,
			want:  false,
		},
		{
			// Regression: a chat content delta that QUOTES "response.created" in
			// its content text must NOT be misread as a Responses boilerplate
			// event — it carries real output and must commit. The old substring
			// check dropped/retried it.
			name:  "chat content delta quoting response.created commits",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"The \"response.created\" event signals the start"},"finish_reason":null}]}`,
			want:  false,
		},
		{
			// Same false positive for the role-only-shaped delta carrying the
			// literal in content: content is non-empty, so it commits.
			name:  "content delta quoting response.in_progress commits",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"see response.in_progress in the docs"},"finish_reason":null}]}`,
			want:  false,
		},
		{
			// A genuine Responses lifecycle event (parsed top-level type) is
			// still boilerplate even when extra fields mention the string.
			name:  "real response.created event with nested mentions is boilerplate",
			chunk: `data: {"type":"response.created","response":{"id":"resp_1","object":"response","status":"in_progress","instructions":"explain response.in_progress"}}`,
			want:  true,
		},
		{
			name:  "complete chat.completion object commits",
			chunk: `data: {"id":"chatcmpl-1","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}]}`,
			want:  false,
		},
		{
			name:  "garbage commits",
			chunk: "data: not json at all",
			want:  false,
		},
		{
			name:  "garbage mentioning role commits",
			chunk: `data: "role" but not json`,
			want:  false,
		},
		{
			name:  "empty string commits",
			chunk: "",
			want:  false,
		},
		{
			name:  "empty choices commits",
			chunk: `data: {"object":"chat.completion.chunk","model":"role-model","choices":[]}`,
			want:  false,
		},
		{
			name:  "delta without role commits",
			chunk: `data: {"object":"chat.completion.chunk","model":"role-model","choices":[{"index":0,"delta":{},"finish_reason":null}]}`,
			want:  false,
		},
		{
			name:  "unknown delta field commits",
			chunk: `data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","audio":{"id":"a1"}},"finish_reason":null}]}`,
			want:  false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := IsBoilerplateChunk(tc.chunk); got != tc.want {
				t.Errorf("isBoilerplateChunk(%q) = %v, want %v", tc.chunk, got, tc.want)
			}
		})
	}
}
