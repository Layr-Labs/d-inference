### Attested registrations advertise Gemma 4 prompt contract 2

- A Mac's registration with Darkbloom now advertises Gemma 4 prompt contract 2 (`gemma_prompt_contract: 2`) when it carries an attestation, which is how every Mac serving the network registers. Until now the attested registration left the field out, so the coordinator never asked a Mac for contract 2 and every Gemma 4 request rendered contract 1.
- Where the coordinator has switched contract 2 on, a Gemma 4 text request served by an updated Mac renders the prompt vLLM-served endpoints render, so its `usage.prompt_tokens` matches theirs. While Macs update, a conversation whose prefix a Mac cached in contract 1 starts cold once in contract 2.
- `DARKBLOOM_GEMMA_PROMPT_CONTRACT_V2=off` still stops a Mac advertising contract 2.
