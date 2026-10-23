### GLM-5.3-Flash serves JSON mode and structured outputs

- Serve `response_format` `json_object` and `json_schema` on GLM-5.3-Flash text requests instead of refusing them with 400 `invalid_request`. GLM's native engine has no constrained decoding, so the format's instruction steers the model, reasoning streams as usual, and the answer is withheld until generation ends. Only a valid JSON value that satisfies the schema is returned, without markdown fences; anything else fails the request with 422 and no content.
- A JSON format combined with tools, a schema outside the supported subset, or image and video input is refused with 400.
