### A two-Mac pair serving locally no longer reloads every half minute when requests queue

- A Gemma 4 pair in tensor parallel, serving locally with requests waiting, tried every 30–40 s to switch to an 8-request pipeline it could not serve the same way (only tensor parallel returns token logprobs). Each attempt stopped serving, failed, and reloaded the model on both Macs for about 15 s, so queued requests waited minutes. A replacement that would change what the API offers is no longer proposed.
- A wider setup that fails to start is now remembered: the same width is not tried again for that setup for 2 minutes, then 4, up to 30, while a changed setup is tried at once.
