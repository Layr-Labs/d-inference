### The cluster setup quotes no speeds, and its recommendation follows the pair's measurements after an update

- `darkbloom cluster`'s model list no longer shows tokens per second. It named each mode with the speed the pair
  served it at ("Gemma 4 26B · tensor parallel 96 tok/s or pipeline (not measured on these Macs yet)"); it now
  names the modes only ("Gemma 4 26B · 15.6 GB · tensor parallel or pipeline"), the fastest measured first. The mode
  question already quoted no speed.
- Right after a Darkbloom update the mode question no longer recommends from the planner's predictions alone. Until
  one of a model's modes has served with the new build, it ranks the modes by what the two Macs served with an earlier
  build, served the same way (through Darkbloom or locally, with or without Qwen's tensor assistant). On one pair the
  question said "Pipeline, faster here" for Gemma 4 26B right after an update, although the pair had served its
  tensor parallel faster with every earlier build; from those measurements it recommends tensor parallel. Once a
  mode has served with the new build, that build's measurement decides, as before. Only when no build has served
  either mode does the planner's prediction decide.
- The developer setup wizard (`darkbloom cluster --wizard`) no longer shows predicted speeds on its model step or a
  speed on its check's result. A test prompt sent from its last step still reports that request's speed.
