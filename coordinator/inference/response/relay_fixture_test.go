package response

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
)

// capturingResponseWriter is countingResponseWriter plus the body itself and
// the size of the largest single Write, so a test can pin both the bytes on
// the wire and the batch size each write carried.
type responseCaptureWriter struct {
	responseCountingWriter
	body     bytes.Buffer
	maxWrite int
}

func newResponseCaptureWriter() *responseCaptureWriter {
	return &responseCaptureWriter{responseCountingWriter: responseCountingWriter{header: make(http.Header)}}
}

func (w *responseCaptureWriter) Write(p []byte) (int, error) {
	if len(p) > w.maxWrite {
		w.maxWrite = len(p)
	}
	w.body.Write(p)
	return w.responseCountingWriter.Write(p)
}

// roleOnlyChunkSSE is the OpenAI boilerplate role-only delta chunk every
// backend emits before any content. Per the WS-C contract it must NOT commit
// the dispatch.
func roleOnlyChunkSSE(model string) string {
	return fmt.Sprintf(`data: {"id":"chatcmpl-failover","object":"chat.completion.chunk","created":1700000000,"model":%q,"choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}`+"\n\n", model)
}

func contentChunkSSE(model, text string) string {
	data, _ := json.Marshal(text)
	return fmt.Sprintf(`data: {"id":"chatcmpl-failover","object":"chat.completion.chunk","created":1700000000,"model":%q,"choices":[{"index":0,"delta":{"content":%s},"finish_reason":null}]}`+"\n\n", model, data)
}

// chatContentChunk is one chat.completion.chunk content delta, framed the way
// the Swift provider frames it (SSE line + blank line).
func chatContentChunk(text string) string {
	return `data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1700000000,"model":"` +
		responseBurstTestModel + `","choices":[{"index":0,"delta":{"content":"` + text + `"},"finish_reason":null}]}` + "\n\n"
}

// countingResponseWriter records writes and flushes without buffering the
// body (the bytes themselves are discarded; only counts matter here).
type responseCountingWriter struct {
	header  http.Header
	status  int
	writes  int
	bytes   int
	flushes int
}

func (w *responseCountingWriter) Header() http.Header { return w.header }

func (w *responseCountingWriter) WriteHeader(code int) { w.status = code }

func (w *responseCountingWriter) Write(p []byte) (int, error) {
	w.writes++
	w.bytes += len(p)
	return len(p), nil
}

func (w *responseCountingWriter) Flush() { w.flushes++ }

const responseAliasQAT = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
const responseBurstTestModel = "burst-model"
