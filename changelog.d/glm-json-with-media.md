### GLM-5.3-Flash answers a JSON format with an image or video on one Mac

- A GLM-5.3-Flash Mac now serves a JSON `response_format` (`json_object` or `json_schema`) together with image or video input. Before, it refused every such request with 400 `invalid_request` ("JSON response_format is not supported with image or video input"); on 11-11 that was ~11.4k OpenRouter requests from one extraction client.
- It works as GLM's text JSON mode does: the instruction renders in the media prompt, reasoning streams on its own channel, and the answer is withheld until generation ends, then checked and exposed once. An answer that isn't the JSON asked for is a 422 with no content.
- Still refused with 400: a required or named `tool_choice` with image or video input, and a JSON format with image or video input on a cluster pair (the pair's media routes don't withhold the answer).
- Darkbloom's coordinator answers these requests itself, without dispatching, for Macs on earlier provider versions.
