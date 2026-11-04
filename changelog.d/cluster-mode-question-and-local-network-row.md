### Two-Mac cluster: the mode question shows what loads

- When you choose how both Macs split a model, each way now shows the split that loads, and the start loads exactly
  that plan. Before, with nothing serving, GLM-5.3-Flash's pipeline was offered as "this Mac 1 layer / the other Mac
  44 layers" and loaded as 44 / 1. A way chosen on the Mac that joined now loads too; before, the leading Mac loaded
  its own first choice.
- Each way also says how many requests it serves at once: "serves one request at a time" for GLM-5.3-Flash's
  pipeline, "serves up to 8 requests at once" for its tensor parallel. On a GLM-5.3-Flash pair, choose tensor
  parallel: through Darkbloom its pipeline turns every other request away as "at capacity".
