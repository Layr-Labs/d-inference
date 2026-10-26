### Diagnostic switch for Qwen tensor-parallel window submission

`DARKBLOOM_QWEN_TP_WINDOW_LAYER_SUBMISSION=0` evaluates every speculative verify
window whole instead of layer by layer, for an A/B on a pair; the default is
unchanged. An installed owner never forwards it to a rank, and both ranks bind
the choice into their load agreement. Evaluation order only: the same values.
