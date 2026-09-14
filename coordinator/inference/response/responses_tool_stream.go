package response

// appendToolCall routes one tool_calls[] fragment to its function_call item.
// Provider chunks key fragments by a stable tool_calls[].index, and fragments
// for several calls may interleave, so each index gets its own item state and
// reserved output_index.
func (e *responsesStreamEmitter) appendToolCall(tc streamToolCallDelta) {
	st := e.activeFnByIndex[tc.Index]
	// Legacy provider builds emit every parallel call at wire index 0 (the
	// engine at this branch's pin assigns distinct indices — see
	// MLXOpenAIService.nextToolCallIndex — but the fleet updates slowly). A
	// different non-empty ID on an active index starts a new logical call;
	// later ID-less argument fragments continue the newest call. This is the
	// same identity rule used by the non-streaming toolCallAccumulator.
	if st != nil && tc.ID != "" && st.wireID != "" && tc.ID != st.wireID {
		st = nil
	}
	if st == nil {
		// Same cap as the non-streaming accumulator: past the limit the new
		// logical call is dropped and its wire index forgotten, so the
		// dropped call's later id-less fragments can never accumulate onto
		// a kept call (they re-enter here and are dropped again).
		if len(e.fnOrder) >= maxLogicalToolCalls {
			delete(e.activeFnByIndex, tc.Index)
			return
		}
		e.closeReasoning()
		e.closeMessage()
		e.sawToolCall = true
		st = &streamFnState{outputIndex: e.outputIndex, wireID: tc.ID}
		e.outputIndex++
		st.itemID = responseItemID("fc", e.pr.RequestID, st.outputIndex)
		st.callID = tc.ID
		if st.callID == "" {
			st.callID = responseItemID("call", e.pr.RequestID, st.outputIndex)
		}
		st.name = tc.Function.Name
		e.activeFnByIndex[tc.Index] = st
		e.fnOrder = append(e.fnOrder, st)
		e.emit("response.output_item.added", map[string]any{
			"output_index": st.outputIndex,
			"item": map[string]any{
				"type":      "function_call",
				"id":        st.itemID,
				"call_id":   st.callID,
				"name":      st.name,
				"arguments": "",
				"status":    "in_progress",
			},
		})
	}
	if tc.ID != "" {
		st.wireID = tc.ID
		st.callID = tc.ID
	}
	if tc.Function.Name != "" {
		st.name = tc.Function.Name
	}
	if tc.Function.Arguments != "" {
		st.argsBuf.WriteString(tc.Function.Arguments)
		e.emit("response.function_call_arguments.delta", map[string]any{
			"item_id":      st.itemID,
			"output_index": st.outputIndex,
			"delta":        tc.Function.Arguments,
		})
	}
}

// hasToolCalls reports whether at least one function_call item was emitted.
func (e *responsesStreamEmitter) hasToolCalls() bool {
	return e.sawToolCall
}

// closeFunctionCalls finalizes all open function_call items in the order they
// were opened, which matches their reserved output indexes.
func (e *responsesStreamEmitter) closeFunctionCalls() {
	for _, state := range e.fnOrder {
		e.closeFunctionCall(state)
	}
	e.fnOrder = nil
	clear(e.activeFnByIndex)
}

func (e *responsesStreamEmitter) closeFunctionCall(st *streamFnState) {
	args := st.argsBuf.String()
	e.emit("response.function_call_arguments.done", map[string]any{
		"item_id":      st.itemID,
		"output_index": st.outputIndex,
		"arguments":    args,
	})
	item := map[string]any{
		"type":      "function_call",
		"id":        st.itemID,
		"call_id":   st.callID,
		"name":      st.name,
		"arguments": args,
		"status":    "completed",
	}
	e.emit("response.output_item.done", map[string]any{
		"output_index": st.outputIndex,
		"item":         item,
	})
	e.output = append(e.output, item)
}
