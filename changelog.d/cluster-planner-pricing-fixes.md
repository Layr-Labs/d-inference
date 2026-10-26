### Cluster planner pricing fixes

- GLM-5.3 Flash tensor parallel: the plan now counts the NextN (MTP) layer every Mac holds beside its share (4.2 GB), the request memory its speculative rounds add, and the decode speed-up the rounds measured, so it no longer admits a pair the load gate then refuses or predicts decode too slow. Two M5 Ultra 256 GB still plan it as tensor parallel on equal shares with eight concurrent requests, on a new pair and after the first load measured the link.
- A pipeline's prompt hop across the cable is priced by the bytes it carries (a GLM chunk is 64 MiB), from the link probe's two record sizes, instead of as one 4 MiB record.
- Requests that answer fewer than 64 tokens (the warm-up canary, the setup's test answer, readiness probes, a quick "Say hi") are no longer speed records, so they no longer choose the mode or the request a plan is made for.
- A Mac with a model loaded no longer runs the GPU speed benchmark when the other Mac checks for updates every minute or plans: it uses the speed index it last measured while idle.
