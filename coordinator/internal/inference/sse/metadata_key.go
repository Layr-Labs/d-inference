package sse

import (
	"strings"
)

const ChatCompletionMetadataField = "metadata"

func DeleteChatCompletionMetadata(obj map[string]any) {
	for key := range obj {
		if strings.EqualFold(key, ChatCompletionMetadataField) {
			delete(obj, key)
		}
	}
}
