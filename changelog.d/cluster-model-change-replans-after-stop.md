### Changing a serving cluster's model plans again once its memory is free

- Changing the model of a serving two-Mac cluster (`m` in `darkbloom cluster`, or `darkbloom cluster local <model>`) now plans again after both Macs have stopped their parts and given back their memory, and starts that plan. Before, it started the plan made while the old parts still held the memory, where tensor parallel did not fit, so a pipeline started instead. GLM-5.3-Flash on two M5 Ultras came back at about half the speed (about 48 instead of about 100 tokens/s), serving the pipeline's 65,536-token context instead of its native 1,048,576.
- The leading Mac's own re-plan after two load refusals for memory starts the plan made once both parts stopped and gave back their memory, too.
