### Gemma 4 tensor parallel on two-Mac clusters

- Gemma 4 26B (QAT 4-bit and 8-bit) can run tensor parallel on a pair: each Mac holds half of every layer's heads and expert channels, both share every token over the encrypted link, and the pair returns the same tokens a single Mac would on the synthetic checks. Text only.
- The planner chooses tensor parallel for Gemma 4 only where it predicts it faster than the pipeline. Two big Macs (for example two M5 Ultra) normally keep the pipeline; smaller Macs with a measured or fast link can get tensor parallel for short prompts with longer answers. Qwen and GLM still choose tensor parallel wherever it fits.
- In tensor parallel, Gemma 4 returns logprobs (`logprobs` / `top_logprobs`), and each Mac reserves memory for its own half of the model: about 8.0 GB of weights at QAT 4-bit (14.9 GB at 8-bit) plus its own KV, with a conservative 5.5 GiB activation reserve until a pair measures one.
- Gemma 4 tensor-parallel pairs serve one request at a time unless `DARKBLOOM_CLUSTER_BATCH_LANES` names more. Speed on a real pair is not measured yet.
