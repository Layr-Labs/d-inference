### Steadier, visible tensor-parallel choice in two-Mac clusters

- Keep each pair's last eight link measurements from the last 30 days and plan
  on their median, so one fast or slow load no longer switches a model between
  tensor parallel and a pipeline. Link files from earlier releases still read.
- End a model's line in the setup's model list with a short reason when the
  model supports tensor parallel but is split otherwise, such as "tensor
  parallel: slower here"; models without tensor parallel show nothing extra.
- Explain that Qwen3.8 27B leaves out the pipeline because only tensor parallel
  keeps images, video and logprobs, instead of saying no pipeline fits.
- Read the saved link measurements in `darkbloom-cluster-plan plan` when
  `--link` is not given (or `--link-probes FILE`), say so, and print reduction
  costs in ms or µs.
