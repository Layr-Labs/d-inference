### Tool calls stream while they are generated

Chat streams now send `tool_choice: "auto"` calls from Gemma 4, Qwen 3.5, 3.6
and 3.8, GPT-OSS and framed-JSON models as OpenAI `tool_calls` fragments while
the model generates them. The call's `id`, `type` and function name arrive as
soon as the name is generated, followed by argument fragments. A response that
started with a tool call previously had no content until the whole call and the
end of generation were produced, so its time to first token included the
entire call. Each call is still validated against its declared tool and schema
when it completes. Required and named tool choices keep validating before
anything is shown.

Long tool calls in the Gemma, GPT-OSS and framed-JSON formats no longer cost
provider CPU time that grew with the square of their length; a 64 KB file
write spent about 20 s of CPU parsing itself.

Qwen-family prompts whose generation prompt carries no think marker (for
example Qwen3-VL Instruct) now stream their answer instead of buffering it
until the end. `DARKBLOOM_TTFT_STREAM_TOOL_CALLS=0` and
`DARKBLOOM_TTFT_THINK_CONTENT_SEED=0` restore the previous behaviors.
