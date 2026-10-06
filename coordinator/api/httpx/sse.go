package httpx

import "strings"

// SSEDataValue decodes an SSE data field without retaining event contents.
func SSEDataValue(line string) (string, bool) {
	line = strings.TrimPrefix(line, "\uFEFF")
	colon := strings.IndexByte(line, ':')
	field, value := line, ""
	if colon >= 0 {
		field, value = line[:colon], line[colon+1:]
		if strings.HasPrefix(value, " ") {
			value = value[1:]
		}
	}
	return value, field == "data"
}
