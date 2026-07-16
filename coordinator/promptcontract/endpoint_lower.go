package promptcontract

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
)

var (
	ErrEndpointBodyNotObject   = errors.New("request body must be a JSON object")
	ErrEndpointBodyInvalid     = errors.New("request endpoint payload is invalid")
	ErrEndpointBodyUnsupported = errors.New("request endpoint payload contains an unsupported item")
)

var (
	chatMediaTypes = map[string]struct{}{
		"image": {}, "image_url": {}, "video": {}, "video_url": {},
	}
	responsesMediaTypes = map[string]struct{}{
		"input_image": {}, "input_file": {}, "image": {}, "image_url": {},
		"video": {}, "video_url": {},
	}
	messagesMediaTypes = map[string]struct{}{
		"image": {}, "document": {},
	}
)

// LowerProviderBody converts an endpoint-native request into the exact OpenAI
// chat-completions object consumed by the provider and prompt sidecar.
func LowerProviderBody(endpoint Endpoint, body []byte) ([]byte, error) {
	object, err := decodeEndpointObject(body)
	if err != nil {
		return nil, err
	}
	if endpointContainsMedia(endpoint, object) {
		return nil, ErrEndpointBodyUnsupported
	}

	var lowered map[string]any
	switch endpoint {
	case EndpointChatCompletions:
		lowered = cloneObject(object)
	case EndpointCompletions:
		lowered, err = lowerCompletions(object)
	case EndpointResponses:
		lowered, err = lowerResponses(object)
	case EndpointMessages:
		lowered, err = lowerMessages(object)
	default:
		err = ErrEndpointBodyInvalid
	}
	if err != nil {
		return nil, err
	}
	return marshalEndpointJSON(lowered)
}

func decodeEndpointObject(body []byte) (map[string]any, error) {
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, ErrEndpointBodyInvalid
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return nil, ErrEndpointBodyInvalid
	}
	object, ok := value.(map[string]any)
	if !ok {
		return nil, ErrEndpointBodyNotObject
	}
	return object, nil
}

func cloneObject(input map[string]any) map[string]any {
	output := make(map[string]any, len(input))
	for key, value := range input {
		output[key] = value
	}
	return output
}

func endpointContainsMedia(endpoint Endpoint, body map[string]any) bool {
	switch endpoint {
	case EndpointChatCompletions:
		return contentCollectionHasMedia(body["messages"], chatMediaTypes)
	case EndpointResponses:
		return contentCollectionHasMedia(body["input"], responsesMediaTypes)
	case EndpointMessages:
		return contentCollectionHasMedia(body["messages"], messagesMediaTypes)
	default:
		return false
	}
}

func contentCollectionHasMedia(value any, mediaTypes map[string]struct{}) bool {
	switch value := value.(type) {
	case []any:
		for _, item := range value {
			if contentCollectionHasMedia(item, mediaTypes) {
				return true
			}
		}
	case map[string]any:
		if kind, ok := value["type"].(string); ok {
			if _, media := mediaTypes[kind]; media {
				return true
			}
		}
		return contentCollectionHasMedia(value["content"], mediaTypes)
	}
	return false
}

func lowerCompletions(input map[string]any) (map[string]any, error) {
	var prompt string
	switch value := input["prompt"].(type) {
	case string:
		prompt = value
	case []any:
		if len(value) != 1 {
			return nil, ErrEndpointBodyUnsupported
		}
		var ok bool
		prompt, ok = value[0].(string)
		if !ok {
			return nil, ErrEndpointBodyUnsupported
		}
	default:
		return nil, ErrEndpointBodyInvalid
	}

	output := cloneObject(input)
	delete(output, "prompt")
	delete(output, "endpoint")
	output["messages"] = []any{
		map[string]any{"role": "user", "content": prompt},
	}
	return output, nil
}

func canonicalRole(role string) (string, bool) {
	switch role {
	case "developer":
		return "system", true
	case "function":
		return "tool", true
	case "system", "user", "assistant", "tool":
		return role, true
	default:
		return "", false
	}
}

func nonEmptyString(value any) (string, bool) {
	text, ok := value.(string)
	return text, ok && text != ""
}

func marshalEndpointJSON(value any) ([]byte, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buffer.Bytes(), []byte{'\n'}), nil
}
