package promptcontract

// PromptMediaCounts retains media costs separately from normalized text. Media
// bytes and URLs never contribute their serialized size to the input floor.
type PromptMediaCounts struct{ Images, Videos int }

// PromptMessagesForEstimate projects only the endpoint's active prompt into the
// same message/text shape used by provider lowering. The projection is private:
// it neither mutates the request nor changes which bodies can be forwarded.
func PromptMessagesForEstimate(endpoint Endpoint, input map[string]any) ([]any, PromptMediaCounts, error) {
	var media PromptMediaCounts
	if endpoint == EndpointChatCompletions {
		messages, ok := input["messages"].([]any)
		if !ok {
			return nil, media, ErrEndpointBodyInvalid
		}
		return messages, media, nil
	}
	// Only prompt fields participate. Tool definitions and sampling options do
	// not affect this estimate or the success of the text projection.
	object := make(map[string]any)
	switch endpoint {
	case EndpointMessages:
		object["messages"] = estimateMessageCollection(input["messages"], endpoint, &media)
		object["system"] = input["system"]
	case EndpointResponses:
		object["input"] = estimateMessageCollection(input["input"], endpoint, &media)
	case EndpointCompletions:
		object["prompt"] = input["prompt"]
	}
	var lowered map[string]any
	var err error
	switch endpoint {
	case EndpointMessages:
		lowered, err = lowerMessages(object)
	case EndpointResponses:
		lowered, err = lowerResponses(object)
	case EndpointCompletions:
		lowered, err = lowerCompletions(object)
	default:
		err = ErrEndpointBodyInvalid
	}
	if err != nil {
		return nil, media, err
	}
	messages, ok := lowered["messages"].([]any)
	if !ok {
		return nil, media, ErrEndpointBodyInvalid
	}
	return messages, media, nil
}

func estimateMessageCollection(value any, endpoint Endpoint, media *PromptMediaCounts) any {
	items, ok := value.([]any)
	if !ok {
		return value
	}
	out := make([]any, len(items))
	for i, item := range items {
		out[i] = item
		if message, ok := item.(map[string]any); ok {
			if endpoint == EndpointResponses {
				kind, hasKind := message["type"].(string)
				_, hasRole := message["role"].(string)
				if (hasKind && kind != "message") || (!hasKind && !hasRole) {
					continue // Only message items consume their content field.
				}
			}
			copy := cloneObject(message)
			copy["content"] = estimateContent(message["content"], media)
			out[i] = copy
		}
	}
	return out
}

func estimateContent(value any, media *PromptMediaCounts) any {
	parts, ok := value.([]any)
	if !ok {
		return value
	}
	out := make([]any, len(parts))
	for i, part := range parts {
		out[i] = part
		object, ok := part.(map[string]any)
		if !ok {
			continue
		}
		switch object["type"] {
		case "image_url", "input_image", "image":
			media.Images++
		case "video_url", "input_video", "video":
			media.Videos++
		default:
			continue
		}
		// Keep the message's position/framing while lowering surrounding text by
		// the canonical rules. The flat media cost is added separately by admission.
		out[i] = map[string]any{"type": "text", "text": ""}
	}
	return out
}
