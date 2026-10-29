### A tensor-parallel cluster registers with the coordinator

- A pair that serves a model in tensor parallel (GLM-5.3-Flash, Qwen3.8-27B) now registers its roster plan with the coordinator. The plan names `tensor_parallel_v1` and no layer cut, as the coordinator requires; before, the member registered the stage end as a cut, refused its own plan, and the pair served only its local API. A setup with unequal tensor-parallel shares is refused at registration until the plan carries its shares.
- The onboarding's start line for a cluster that serves through Darkbloom no longer says public serving is off in this build: it serves its owner's requests, and public requests where Darkbloom has qualified the model and split.
- A plan in `pipeline_prefill_tensor_decode_v1` (pipeline prefill, tensor-parallel decode) also registers: the coordinator lists the mode, and the member no longer refuses its own plan.
