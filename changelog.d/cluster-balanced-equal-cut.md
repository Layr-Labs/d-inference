### Identical Macs split a model evenly

- When cuts predict the same request time (identical Macs, or equal measured speeds), the placement planner now chooses the one that uses each Mac's hardware capacity most evenly, instead of the earliest cut the second Mac's free memory held at that moment. Two M5 Ultra 256 GB had planned GLM-5.3-Flash 11/34 and then 5/40 of its 45 layers; they now plan it 22/23 whichever Mac leads. A faster split is never traded for balance, and the "Quit apps first" refusal is unchanged. This applies to every model the cluster plans.
