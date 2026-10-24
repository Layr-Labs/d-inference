### `darkbloom logs` names why a request was refused before it ran

A request the provider refused before its inference task started (an
unsupported reasoning control, a malformed tool history, a body that does not
decode, a sealed request it cannot open) wrote no readable log line, although
coordinators count it as a failed job. Each such refusal now writes one fixed
line, for example
`Inference failure: invalid request (unsupported reasoning control)`, so the
failed jobs on the console's Jobs card can be matched in `darkbloom logs`. The
line never contains request text, and the refusal itself is unchanged.
