package promptcontract

import "strings"

// LowerResponsesInferenceBody prepares Responses input for actual inference.
// Cache planning continues to use the separately media-ineligible contract.
func LowerResponsesInferenceBody(body []byte) ([]byte, error) {
	input, err := decodeEndpointObject(body)
	if err != nil {
		return nil, err
	}
	output, err := lowerResponsesWithContent(input, responsesInferenceContent)
	if err != nil {
		return nil, err
	}
	return marshalEndpointJSON(output)
}

func responsesInferenceContent(content any) (any, error) {
	parts, ok := content.([]any)
	if !ok {
		if object, ok := content.(map[string]any); ok {
			kind, _ := object["type"].(string)
			if _, media := responsesMediaTypes[kind]; media || kind == "input_audio" {
				return nil, ErrEndpointBodyUnsupported
			}
		}
		return responsesContentText(content), nil
	}
	output := make([]any, 0, len(parts))
	hasMedia := false
	for _, value := range parts {
		if text, ok := value.(string); ok {
			output = append(output, map[string]any{"type": "text", "text": text})
			continue
		}
		part, ok := value.(map[string]any)
		if !ok {
			return nil, ErrEndpointBodyInvalid
		}
		kind, _ := part["type"].(string)
		switch kind {
		case "", "text", "input_text", "output_text":
			text, ok := part["text"].(string)
			if !ok {
				return nil, ErrEndpointBodyInvalid
			}
			output = append(output, map[string]any{"type": "text", "text": text})
		case "input_image", "image_url", "video_url":
			if id, exists := part["file_id"]; exists && id != nil {
				return nil, ErrEndpointBodyUnsupported
			}
			field := "image_url"
			if kind == "video_url" {
				field = "video_url"
			}
			var media map[string]any
			if kind == "input_image" {
				url, ok := part[field].(string)
				if !ok {
					return nil, ErrEndpointBodyInvalid
				}
				media = map[string]any{"url": url}
				if detail, exists := part["detail"]; exists {
					media["detail"] = detail
				}
			} else {
				object, ok := part[field].(map[string]any)
				if !ok {
					return nil, ErrEndpointBodyInvalid
				}
				media = cloneObject(object)
			}
			url, ok := media["url"].(string)
			if !ok || url == "" {
				return nil, ErrEndpointBodyInvalid
			}
			// Responses never fetched remote media. Keep that privacy/SSRF
			// boundary: serving this endpoint accepts inline media only.
			if len(url) < 5 || !strings.EqualFold(url[:5], "data:") {
				return nil, ErrEndpointBodyUnsupported
			}
			output = append(output, map[string]any{"type": field, field: media})
			hasMedia = true
		default:
			return nil, ErrEndpointBodyUnsupported
		}
	}
	if !hasMedia {
		return responsesContentText(content), nil
	}
	return output, nil
}
