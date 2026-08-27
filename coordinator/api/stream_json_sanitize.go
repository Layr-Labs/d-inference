package api

import "strings"

func sseDataValue(line string) (string, bool) {
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

// sanitizeStreamJSONEventGroup applies a JSON-object sanitizer to one bare JSON
// payload or SSE event while preserving non-data SSE fields. An empty sanitized
// payload drops the event's data fields, allowing security filters to fail
// closed without relaying parser-differential input.
func sanitizeStreamJSONEventGroup(
	group string,
	sanitizeJSON func(string) (string, bool),
) (string, bool) {
	lines := strings.Split(group, "\n")
	data := make([]string, 0, len(lines))
	firstData := -1
	for i, line := range lines {
		if value, ok := sseDataValue(line); ok {
			if firstData < 0 {
				firstData = i
			}
			data = append(data, value)
		}
	}
	if firstData < 0 {
		if len(lines) == 1 {
			if sanitized, ok := sanitizeJSON(strings.TrimSpace(group)); ok {
				return sanitized, true
			}
		}
		return group, false
	}
	sanitized, changed := sanitizeJSON(strings.Join(data, "\n"))
	if !changed {
		return group, false
	}
	out := make([]string, 0, len(lines)-len(data)+1)
	for i, line := range lines {
		if _, ok := sseDataValue(line); ok {
			if i == firstData && sanitized != "" {
				out = append(out, "data: "+sanitized)
			}
			continue
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n"), true
}
