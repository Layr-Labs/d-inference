### A pair's pipeline Mac that runs short of memory ends only that request

- When a pipeline Mac's memory refuses a request while it runs (Qwen, Gemma 4 and GLM pipelines), both Macs now end that request alone and keep serving. A local request that isn't streamed gets one Mac's memory 503, "This Mac's memory can't hold this request right now. …". A streamed one gets the tokens already sent, then an error chunk with `code` `request_exceeds_node_budget` and the same words. Darkbloom traffic gets `capacity` with `request_exceeds_node_budget`. Before, the refusing Mac's worker exited, the client got an untyped 500 and the pair stopped serving for about a minute.
- MiMo V2.6's pipeline and every tensor-parallel mode still end a worker in this case.
