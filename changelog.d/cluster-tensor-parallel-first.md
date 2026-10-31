### Two-Mac clusters place tensor parallel first wherever it fits

- A model whose tensor-parallel layout fits both Macs is now set up in tensor parallel even where the speed estimate favored a pipeline; the setup says so ("the model fits, so both Macs share every layer of every token") instead of claiming a gain it does not predict. A setup that loads now still goes ahead of tensor parallel that would not, and predictions are still shown.
- A new pair's first setup is tensor parallel too: before any load has measured the cable, it plans on the same assumed sealed reduction a forced plan uses, labelled as assumed.
- Automatic widening never assumes a link cost: it plans only on the pair's own recent sealed link measurement, and without one it keeps the running setup.
- `darkbloom-cluster-plan plan --tensor-parallel-first` plans the same way; without the flag the plan tool keeps the speed comparison.
