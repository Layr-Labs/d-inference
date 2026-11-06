### The cluster setup quotes no speeds, and its recommendation follows the pair's measurements after an update

- `darkbloom cluster`'s model list no longer shows tokens per second. It named each mode with the speed the pair
  served it at ("Gemma 4 26B · tensor parallel 96 tok/s or pipeline (not measured on these Macs yet)"); it now
  names the modes only ("Gemma 4 26B · 15.6 GB · tensor parallel or pipeline"), the one the mode question recommends
  first. A model named on the command line (`darkbloom cluster local <model>`) starts in that mode too. The mode
  question already quoted no speed.
- After a Darkbloom update, until one of a model's modes has served with the new build, the mode question ranks the
  modes by what the two Macs served with an earlier build that recorded how it served (through Darkbloom or locally,
  with or without Qwen's tensor assistant). Builds record this from 0.10.11 on, so it first applies at the update
  after 0.10.11: updating from 0.10.10, whose records don't say how they were served, the question still recommends
  from the planner's prediction until a mode has served with 0.10.11. Once a mode has served with the new build, that
  build's measurement decides, as before. On one DevNet pair the question said "Pipeline, faster here" for Gemma 4 26B
  right after an update, although the pair had served tensor parallel faster before; from its earlier
  tensor-parallel measurement it now recommends tensor parallel.
- The developer setup wizard (`darkbloom cluster --wizard`) no longer shows predicted speeds on its model step or its
  help, or a speed on its check's result. A test prompt sent from its last step still reports that request's speed.
