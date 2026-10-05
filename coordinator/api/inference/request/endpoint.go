package request

const (
	CompletionsEndpoint = "/v1/completions"
	MessagesEndpoint    = "/v1/messages"
)

func GenericResponseMetadata(endpoint string, parsed map[string]any) (string, []string) {
	if endpoint == MessagesEndpoint {
		return endpoint, requestedMessagesStopSequences(parsed)
	}
	return endpoint, nil
}
