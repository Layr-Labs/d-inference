### GLM-5.3-Flash serves a JSON `response_format` beside tools

A GLM-5.3-Flash request with a JSON `response_format` (`json_object` or
`json_schema`) and declared tools was refused with HTTP 400 before generation.
It is now served as on the other families: the format governs the answer, which
is withheld until it validates, while a tool call is exposed and validated as
in any tool request. Text the model writes beside a call is not checked against
the format; it is sent unchanged once generation ends.
