### A cancelled row's slot goes to the next request

- A request that arrives on a full Mac while a cancelled row is still giving back its slot is admitted at the release, instead of a capacity 503. A cancelled row keeps its serving slot, whole-Mac share and KV until the engine drops it at its next step and its cleanup ends; the refusal now waits up to 2 s for that release and then asks once more. Nothing is admitted before the release, and with no cancelled row the refusal is immediate, as before. This applies to every model.
- `DARKBLOOM_CANCELLED_ROW_ADMISSION_WAIT=0` refuses at once, as before.
- A client that closes a stream normally (a FIN) is noticed only when the next chunk cannot be written, because the server allows input half-close. A request sent before that moment is still refused.
