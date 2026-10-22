### Local Responses continuation and reasoning

- Continue local Responses requests with `previous_response_id`, preserving input, reasoning and correlated tool history. Reject non-null invalid ID types and unavailable IDs with HTTP 400 before model acquisition; null remains absence.
- Bound continuation history with an application-local LRU. Response retrieval uses a separate in-memory object store, so a retrievable response can have expired continuation history; neither store survives application restart. `store: false` suppresses both new saves.
- Select omitted local reasoning parsers by model type while preserving explicit overrides. Keep unfinished prompt-side thinking in reasoning fields for collected Chat and Responses, retrieval and continued history, with the paired SDK parser repair; native parsed channels and token usage remain authoritative.
