### Two-Mac pairs: the guided setup lists the models right after both cluster services start

- Run right after both Macs' cluster services started (for example after updating both Macs with the pair stopped), `darkbloom cluster` on the leading Mac could read both Macs, then fail to plan with "The other Mac has not answered yet." and offer only "Start over (unpair and set up again)" or "Quit". The plan now asks the other Mac first when it has no answer of its own, so the model list appears as usual.
