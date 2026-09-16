package response

func (e *responsesStreamEmitter) appendContent(delta string) {
	e.ensureMessageOpen()
	e.contentBuf.WriteString(delta)
	e.emit("response.output_text.delta", map[string]any{
		"item_id":       e.messageItemID,
		"output_index":  e.outputIndex,
		"content_index": 0,
		"delta":         delta,
		"logprobs":      []any{},
	})
}

func (e *responsesStreamEmitter) ensureMessageOpen() {
	if !e.messageOpen {
		e.closeReasoning()
		e.closeFunctionCalls()
		e.contentBuf.Reset()
		e.messageOpen = true
		e.messageItemID = responseItemID("msg", e.pr.RequestID, e.outputIndex)
		e.emit("response.output_item.added", map[string]any{
			"output_index": e.outputIndex,
			"item": map[string]any{
				"type":    "message",
				"id":      e.messageItemID,
				"role":    "assistant",
				"content": []any{},
				"status":  "in_progress",
			},
		})
		e.emit("response.content_part.added", map[string]any{
			"item_id":       e.messageItemID,
			"output_index":  e.outputIndex,
			"content_index": 0,
			"part":          map[string]any{"type": "output_text", "text": "", "annotations": []any{}},
		})
	}
}

func (e *responsesStreamEmitter) closeMessage() {
	if !e.messageOpen {
		return
	}
	text := e.contentBuf.String()
	e.emit("response.output_text.done", map[string]any{
		"item_id":       e.messageItemID,
		"output_index":  e.outputIndex,
		"content_index": 0,
		"text":          text,
		"logprobs":      []any{},
	})
	e.emit("response.content_part.done", map[string]any{
		"item_id":       e.messageItemID,
		"output_index":  e.outputIndex,
		"content_index": 0,
		"part":          map[string]any{"type": "output_text", "text": text, "annotations": []any{}},
	})
	item := map[string]any{
		"type": "message",
		"id":   e.messageItemID,
		"role": "assistant",
		"content": []any{map[string]any{
			"type":        "output_text",
			"text":        text,
			"annotations": []any{},
		}},
		"status": "completed",
	}
	e.emit("response.output_item.done", map[string]any{
		"output_index": e.outputIndex,
		"item":         item,
	})
	e.output = append(e.output, item)
	e.outputIndex++
	e.messageOpen = false
}
