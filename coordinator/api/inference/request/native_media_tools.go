package request

// Inspect typed message/output positions only, never tool arguments or strings.
func RequestHasMediaToolResults(parsed map[string]any) bool {
	for _, field := range []string{"messages", "input"} {
		items, _ := parsed[field].([]any)
		for _, value := range items {
			item, ok := value.(map[string]any)
			if !ok {
				continue
			}
			var content any
			if field == "input" && item["type"] == "function_call_output" {
				content = item["output"]
			} else if item["role"] == "tool" || item["role"] == "function" {
				content = item["content"]
			}
			if _, media := contentShape(content); media > 0 {
				return true
			}
		}
	}
	return false
}
