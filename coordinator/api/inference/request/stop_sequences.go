package request

func requestedMessagesStopSequences(parsed map[string]any) []string {
	raw, ok := parsed["stop_sequences"].([]any)
	if !ok || len(raw) == 0 {
		return nil
	}
	sequences := make([]string, 0, len(raw))
	for _, value := range raw {
		if sequence, ok := value.(string); ok {
			sequences = append(sequences, sequence)
		}
	}
	return sequences
}
