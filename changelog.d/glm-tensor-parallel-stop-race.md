### A GLM pair's stop just before an end token no longer hangs the request

- On a GLM-5.3-Flash tensor-parallel pair that decodes one token a step, a request could stall and fail on both Macs when it stopped just before the model's end token: for example when a stop string matched and the next token was the end of the answer. The stopped Mac built one more step alone and waited in a collective the other Mac, which had already ended at that token, never joined. Both Macs now end at that token and return the text up to the stop.
- Pairs that decode with the model's own speculative (MTP) layer, which every v0.10.6 pair does for every request, already ended there and are unchanged.
