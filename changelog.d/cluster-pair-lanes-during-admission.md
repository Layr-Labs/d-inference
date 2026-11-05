### A two-Mac pair keeps its requests streaming while it admits another

- On a pair that serves several requests at once (GLM-5.3-Flash in tensor parallel serves up to 8), every running request's tokens waited while the pair admitted a new one. Under steady traffic, streaming fell to a few tokens a second. Running requests now keep streaming during an admission.
- A request the pair is admitting, or about to admit, now counts as a place taken in what the pair reports to Darkbloom. Before, Darkbloom could send one more request than the pair had room for, and the pair refused it ("provider capacity unavailable").
- A cancel now takes effect at once, even while the pair admits another request.
