### MiMo-V2.6-Flash and Gemma 4 26B QAT serve public cluster traffic

- Two more models are approved for public traffic on two-Mac clusters, in pipeline and tensor parallel, as GLM-5.3-Flash and Qwen3.8 27B are: MiMo-V2.6-Flash (`mimo-v2.6-flash-mopd`) and Gemma 4 26B QAT (`gemma-4-26b-qat-4bit`). A release's cluster runtime facts carry their pair-serving grants and parity qualifications, so a pair of either model earns through Darkbloom on any Apple silicon pair, and `darkbloom cluster` lists them.
- Their tensor parallel serves once its code is in the build (Gemma 4 and MiMo tensor parallel PRs); until then they pair as a pipeline. MiMo-V2.6-Flash's speculative pipeline, its default split, is declared too.
