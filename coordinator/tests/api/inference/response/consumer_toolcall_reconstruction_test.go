package response_test

func tcDelta(index int, id, name, args string) string {
	chunk := `data: {"choices":[{"delta":{"tool_calls":[{"index":` + itoa(index)
	if id != "" {
		chunk += `,"id":"` + id + `"`
	}
	chunk += `,"function":{`
	sep := ""
	if name != "" {
		chunk += `"name":"` + name + `"`
		sep = ","
	}
	chunk += sep + `"arguments":` + quoteJSON(args) + `}}]}}]}`
	return chunk
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	digits := ""
	for n > 0 {
		digits = string(rune('0'+n%10)) + digits
		n /= 10
	}
	return digits
}

func quoteJSON(s string) string {
	out := `"`
	for _, r := range s {
		switch r {
		case '"':
			out += `\"`
		case '\\':
			out += `\\`
		default:
			out += string(r)
		}
	}
	return out + `"`
}
