### Images in system, assistant and tool messages

- An image or video in a system, assistant or tool message is now kept and placed where the model's chat template places it, as vLLM does. Before, a request whose only image sat in one of those messages was refused with 400 "Invalid media input.", and beside a user image the other images were dropped, so the model answered without seeing them.
- Where the template itself refuses the image or has no place for it (Qwen 3.5–3.8 refuse a system-message image; Gemma 4 renders only the text of its first system message and of tool results), the request fails with a clear 400, refusal reason `media_role_not_rendered`, the same request vLLM refuses.
- Requests whose images are only in user messages are built exactly as before. `DARKBLOOM_MEDIA_ON_EVERY_ROLE=0` restores the old behaviour.
