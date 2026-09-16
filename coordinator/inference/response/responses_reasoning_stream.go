package response

func (e *responsesStreamEmitter) appendReasoning(delta string) {
	if !e.reasoningOpen {
		e.closeOpenItems()
		e.reasoningBuf.Reset()
		e.reasoningOpen = true
		e.reasoningItemID = responseItemID("rs", e.pr.RequestID, e.outputIndex)
		e.emit("response.output_item.added", map[string]any{
			"output_index": e.outputIndex,
			"item": map[string]any{
				"type":    "reasoning",
				"id":      e.reasoningItemID,
				"summary": []any{},
				"status":  "in_progress",
			},
		})
		e.emit("response.reasoning_summary_part.added", map[string]any{
			"item_id":       e.reasoningItemID,
			"output_index":  e.outputIndex,
			"summary_index": 0,
			"part":          map[string]any{"type": "summary_text", "text": ""},
		})
	}
	e.reasoningBuf.WriteString(delta)
	e.emit("response.reasoning_summary_text.delta", map[string]any{
		"item_id":       e.reasoningItemID,
		"output_index":  e.outputIndex,
		"summary_index": 0,
		"delta":         delta,
	})
}

func (e *responsesStreamEmitter) closeReasoning() {
	if !e.reasoningOpen {
		return
	}
	text := e.reasoningBuf.String()
	e.emit("response.reasoning_summary_text.done", map[string]any{
		"item_id":       e.reasoningItemID,
		"output_index":  e.outputIndex,
		"summary_index": 0,
		"text":          text,
	})
	e.emit("response.reasoning_summary_part.done", map[string]any{
		"item_id":       e.reasoningItemID,
		"output_index":  e.outputIndex,
		"summary_index": 0,
		"part":          map[string]any{"type": "summary_text", "text": text},
	})
	item := map[string]any{
		"type":    "reasoning",
		"id":      e.reasoningItemID,
		"summary": []any{map[string]any{"type": "summary_text", "text": text}},
		"status":  "completed",
	}
	e.emit("response.output_item.done", map[string]any{
		"output_index": e.outputIndex,
		"item":         item,
	})
	e.output = append(e.output, item)
	e.outputIndex++
	e.reasoningOpen = false
}
