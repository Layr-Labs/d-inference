### Inkling 2 Mini reads system messages sent mid-conversation

A system message sent after the first turn now joins the leading system message for Inkling 2 Mini, in order and separated by a blank line, as it already does for Qwen 3.5 and GPT-OSS. Rendered where it was sent, such an instruction could keep the model's reasoning searching for it until the request ended at its token limit with no answer. Requests with a single leading system message render as before. `DARKBLOOM_INKLING_FOLD_SYSTEM=0` renders later system messages where they were sent.
