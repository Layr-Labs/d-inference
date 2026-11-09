### A Gemma 4 pair's pipeline serves the model's whole context again

- A Gemma 4 26B pair in the pipeline again accepts prompts up to 262,143 tokens and up to 32,768 output tokens within 262,144, as in tensor parallel and on one Mac. 0.10.11 held its pipeline to the 32,768 + 32,768-token request. A pipeline Mac whose memory refuses a running request ends only that request, as since 0.10.11. Each Mac's memory gate still decides, request by request, whether a longer one fits now.
