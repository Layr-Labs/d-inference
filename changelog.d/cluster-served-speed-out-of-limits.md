### A pair keeps a model on its list after a request longer than the model's limit

- A pair no longer loses a model from its list after serving a request longer than the model's limit. On two M5 Ultras, Qwen 3.8 27B vanished from `darkbloom cluster`, and `darkbloom start` could not start it, after the pair served prompts of 71,545 to 94,423 tokens in tensor parallel. The next plan now skips each such served request, says in one line how many it skipped, and still uses every other request the pair served.
- A model approved for clusters that can't be offered on these two Macs now says why, in one line above the model list (for example "Qwen 3.8 27B: not offered on these two Macs: …"), instead of disappearing.
