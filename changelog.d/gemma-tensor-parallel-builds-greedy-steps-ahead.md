### Gemma tensor parallel prepares the next token while reading the last

- For requests without sampling (temperature 0, no logprobs, no logit bias or penalties), a Gemma 4 pair now starts the next token's work on the GPU before it reads the token it just made, as GLM's pair already does. On GLM this took a token from 13.4 to 12.0 ms on two M5 Ultras; Gemma's gain has not been measured yet. The output is unchanged.
