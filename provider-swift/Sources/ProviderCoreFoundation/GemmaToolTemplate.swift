// Copyright © 2026 Eigen Labs.
//
// Vendored, upstream-fixed Gemma 4 tool-calling chat template (DAR-329).
//
// The `mlx-community/gemma-4-26B-A4B-it-qat-4bit` snapshot we serve ships an
// OUTDATED `chat_template.jinja` whose tool-schema rendering pipes `| upper`
// (and `| map('upper')`) over `value['type']` WITHOUT a null/Optional guard.
// swift-jinja's `upper` filter throws `"upper filter requires string"` on any
// non-string value, so a tool whose schema carries a union type
// (`"type": ["string","null"]`), omits `type`, or whose enum holds a
// non-string element renders to a hard 500 (`Jinja.TemplateException`).
//
// The fixed upstream revision — published as
// `lmstudio-community/gemma-4-26B-A4B-it-QAT-MLX-4bit` — null-guards every
// `type` access and adds a `format_type_argument` macro that handles string /
// list / absent type values. The two repos are the SAME qat-4bit weights and
// tokenizer (byte-identical safetensors + tokenizer.json); the ONLY functional
// delta is this template, so adopting it is a template-only fix that needs no
// requant / reweight / tokenizer change.
//
// This is the verified upstream file, embedded byte-for-byte (see
// `GemmaToolTemplateTests`, which asserts the sha256 below and that it renders
// every canonical fixture in the exact swift-jinja engine the runtime uses).
// It is applied as a NON-MUTATING, hash-gated render-time override
// (`ChatTemplateOverride`): the on-disk `chat_template.jinja` is left untouched
// so the model's attestation/integrity hash (`WeightHasher.computeHash`, which
// includes `chat_template.jinja`) keeps matching the published registry
// manifest. The override self-disables automatically once the registry
// republishes the corrected template (the on-disk hash stops matching).
//
// Provenance / regeneration:
//   curl -sSL https://huggingface.co/lmstudio-community/gemma-4-26B-A4B-it-QAT-MLX-4bit/resolve/main/chat_template.jinja
//   (sha256 29af862bccabb14b90a4ff951bcd14c33fe74b651c5f07fc7f2e9aa46a59fe7c)

import Foundation

public enum GemmaToolTemplate {
    /// sha256 of `mlx-community/gemma-4-26B-A4B-it-qat-4bit`'s shipped
    /// (broken) `chat_template.jinja` — the exact revision this override
    /// replaces. Gating on the content hash keeps the override surgical: it
    /// fires ONLY for that one known-broken file and no other model/template.
    public static let brokenSHA256 =
        "94899c0f917d93f6fe81c95744d1e8ddab2d21d39228d2e4aec1fb2a25bff413"

    /// sha256 of the embedded corrected template below (the upstream
    /// `lmstudio-community` revision). Pinned so a test can prove the vendored
    /// bytes are exactly the verified upstream file.
    public static let correctedSHA256 =
        "29af862bccabb14b90a4ff951bcd14c33fe74b651c5f07fc7f2e9aa46a59fe7c"

    /// The upstream-fixed Gemma 4 tool-calling chat template, byte-for-byte.
    public static let correctedToolTemplate: String = #"""
{%- macro format_type_argument(type_value) -%}
    {%- if type_value is string -%}
        {{- '<|"|>' + (type_value | upper) + '<|"|>' -}}
    {%- elif type_value is iterable -%}
        [
        {%- for item in type_value -%}
            <|"|>{{- item | upper -}}<|"|>
            {%- if not loop.last %},{% endif -%}
        {%- endfor -%}
        ]
    {%- else -%}
        {{- format_argument(type_value) -}}
    {%- endif -%}
{%- endmacro -%}
{%- macro format_parameters(properties, required, filter_keys=false) -%}
    {%- set standard_keys = ['description', 'type', 'properties', 'required', 'nullable'] -%}
    {%- set ns = namespace(found_first=false) -%}
    {%- for key, value in properties | dictsort -%}
        {%- set add_comma = false -%}
        {%- if not filter_keys or key not in standard_keys -%}
            {%- if ns.found_first %},{% endif -%}
            {%- set ns.found_first = true -%}
            {{ key }}:{
            {%- if value['description'] -%}
                description:<|"|>{{ value['description'] }}<|"|>
                {%- set add_comma = true -%}
            {%- endif -%}
            {%- if value['type'] and ('string' in value['type'] or 'STRING' in value['type']) -%}
                {%- if value['enum'] -%}
                    {%- if add_comma %},{%- else -%} {%- set add_comma = true -%} {% endif -%}
                    enum:{{ format_argument(value['enum']) }}
                {%- endif -%}
            {%- elif value['type'] and ('array' in value['type'] or 'ARRAY' in value['type']) -%}
                {%- if value['items'] is mapping and value['items'] -%}
                    {%- if add_comma %},{%- else -%} {%- set add_comma = true -%} {% endif -%}
                    items:{
                    {%- set ns_items = namespace(found_first=false) -%}
                    {%- for item_key, item_value in value['items'] | dictsort -%}
                        {%- if item_value is not none -%}
                            {%- if ns_items.found_first %},{% endif -%}
                            {%- set ns_items.found_first = true -%}
                            {%- if item_key == 'properties' -%}
                                properties:{
                                {%- if item_value is mapping -%}
                                    {{- format_parameters(item_value, value['items']['required'] | default([])) -}}
                                {%- endif -%}
                                }
                            {%- elif item_key == 'required' -%}
                                required:[
                                {%- for req_item in item_value -%}
                                    <|"|>{{- req_item -}}<|"|>
                                    {%- if not loop.last %},{% endif -%}
                                {%- endfor -%}
                                ]
                            {%- elif item_key == 'type' -%}
                                type:{{ format_type_argument(item_value) }}
                            {%- else -%}
                                {{ item_key }}:{{ format_argument(item_value) }}
                            {%- endif -%}
                        {%- endif -%}
                    {%- endfor -%}
                    }
                {%- endif -%}
            {%- endif -%}
            {%- if value['nullable'] %}
                {%- if add_comma %},{%- else -%} {%- set add_comma = true -%} {% endif -%}
                nullable:true
            {%- endif -%}
            {%- if value['type'] and ('object' in value['type'] or 'OBJECT' in value['type']) -%}
                {%- if value['properties'] is defined and value['properties'] is mapping -%}
                    {%- if add_comma %},{%- else -%} {%- set add_comma = true -%} {% endif -%}
                    properties:{
                    {{- format_parameters(value['properties'], value['required'] | default([])) -}}
                    }
                {%- elif value is mapping -%}
                    {%- if add_comma %},{%- else -%} {%- set add_comma = true -%} {% endif -%}
                    properties:{
                    {{- format_parameters(value, value['required'] | default([]), filter_keys=true) -}}
                    }
                {%- endif -%}
                {%- if value['required'] -%}
                    {%- if add_comma %},{%- else -%} {%- set add_comma = true -%} {% endif -%}
                    required:[
                    {%- for item in value['required'] | default([]) -%}
                        <|"|>{{- item -}}<|"|>
                        {%- if not loop.last %},{% endif -%}
                    {%- endfor -%}
                    ]
                {%- endif -%}
            {%- endif -%}
            {%- if add_comma %},{%- else -%} {%- set add_comma = true -%} {% endif -%}
            type:{{ format_type_argument(value['type']) }}}
        {%- endif -%}
    {%- endfor -%}
{%- endmacro -%}
{%- macro format_function_declaration(tool_data) -%}
    declaration:{{- tool_data['function']['name'] -}}{description:<|"|>{{- tool_data['function']['description'] -}}<|"|>
    {%- set params = tool_data['function']['parameters'] -%}
    {%- if params -%}
        ,parameters:{
        {%- set ns_params = namespace(found_first=false) -%}
        {%- if params['properties'] -%}
            properties:{ {{- format_parameters(params['properties'], params['required']) -}} }
            {%- set ns_params.found_first = true -%}
        {%- endif -%}
        {%- if params['required'] -%}
            {%- if ns_params.found_first %},{% endif -%}
            required:[
            {%- for item in params['required'] -%}
                <|"|>{{- item -}}<|"|>
                {{- ',' if not loop.last -}}
            {%- endfor -%}
            ]
            {%- set ns_params.found_first = true -%}
        {%- endif -%}
        {%- if params['type'] -%}
            {%- if ns_params.found_first %},{% endif -%}
            type:{{- format_type_argument(params['type']) -}}
        {%- endif -%}
        }
    {%- endif -%}
    {%- if 'response' in tool_data['function'] -%}
        {%- set response_declaration = tool_data['function']['response'] -%}
        ,response:{
        {%- set ns_response = namespace(found_first=false) -%}
        {%- if response_declaration['description'] -%}
            description:<|"|>{{- response_declaration['description'] -}}<|"|>
            {%- set ns_response.found_first = true -%}
        {%- endif -%}
        {%- if response_declaration['type'] -%}
            {%- if ns_response.found_first %},{% endif -%}
            type:{{- format_type_argument(response_declaration['type']) -}}
        {%- endif -%}
        }
    {%- endif -%}
    }
{%- endmacro -%}
{%- macro format_argument(argument, escape_keys=True) -%}
    {%- if argument is string -%}
        {{- '<|"|>' + argument + '<|"|>' -}}
    {%- elif argument is boolean -%}
        {{- 'true' if argument else 'false' -}}
    {%- elif argument is mapping -%}
        {{- '{' -}}
        {%- set ns = namespace(found_first=false) -%}
        {%- for key, value in argument | dictsort -%}
            {%- if ns.found_first %},{% endif -%}
            {%- set ns.found_first = true -%}
            {%- if escape_keys -%}
                {{- '<|"|>' + key + '<|"|>' -}}
            {%- else -%}
                {{- key -}}
            {%- endif -%}
            :{{- format_argument(value, escape_keys=escape_keys) -}}
        {%- endfor -%}
        {{- '}' -}}
    {%- elif argument is iterable -%}
        {{- '[' -}}
        {%- for item in argument -%}
            {{- format_argument(item, escape_keys=escape_keys) -}}
            {%- if not loop.last %},{% endif -%}
        {%- endfor -%}
        {{- ']' -}}
    {%- else -%}
        {{- argument -}}
    {%- endif -%}
{%- endmacro -%}
{%- macro strip_thinking(text) -%}
    {%- set ns = namespace(result='') -%}
    {%- for part in text.split('<channel|>') -%}
        {%- if '<|channel>' in part -%}
            {%- set ns.result = ns.result + part.split('<|channel>')[0] -%}
        {%- else -%}
            {%- set ns.result = ns.result + part -%}
        {%- endif -%}
    {%- endfor -%}
    {{- ns.result | trim -}}
{%- endmacro -%}

{%- macro format_tool_response_block(tool_name, response) -%}
    {{- '<|tool_response>' -}}
    {%- if response is mapping -%}
        {{- 'response:' + tool_name + '{' -}}
        {%- for key, value in response | dictsort -%}
            {{- key -}}:{{- format_argument(value, escape_keys=False) -}}
            {%- if not loop.last %},{% endif -%}
        {%- endfor -%}
        {{- '}' -}}
    {%- else -%}
        {{- 'response:' + tool_name + '{value:' + format_argument(response, escape_keys=False) + '}' -}}
    {%- endif -%}
    {{- '<tool_response|>' -}}
{%- endmacro -%}

{%- set ns = namespace(prev_message_type=None) -%}
{%- set loop_messages = messages -%}
{{- bos_token -}}
{#- Handle System/Tool Definitions Block -#}
{%- if (enable_thinking is defined and enable_thinking) or tools or messages[0]['role'] in ['system', 'developer'] -%}
    {{- '<|turn>system\n' -}}
    {#- Inject Thinking token at the very top of the FIRST system turn -#}
    {%- if enable_thinking is defined and enable_thinking -%}
        {{- '<|think|>\n' -}}
        {%- set ns.prev_message_type = 'think' -%}
    {%- endif -%}
    {%- if messages[0]['role'] in ['system', 'developer'] -%}
        {%- if messages[0]['content'] is string -%}
            {{- messages[0]['content'] | trim -}}
        {%- elif messages[0]['content'] is iterable -%}
            {%- for item in messages[0]['content'] -%}
                {{- item['text'] | trim + ' '-}}
            {%- endfor -%}
        {%- endif -%}
        {%- set loop_messages = messages[1:] -%}
    {%- endif -%}
    {%- if tools -%}
        {%- for tool in tools %}
            {{- '<|tool>' -}}
            {{- format_function_declaration(tool) | trim -}}
            {{- '<tool|>' -}}
        {%- endfor %}
        {%- set ns.prev_message_type = 'tool' -%}
    {%- endif -%}
    {{- '<turn|>\n' -}}
{%- endif %}

{#- Pre-scan: find last user message index for reasoning guard -#}
{%- set ns_turn = namespace(last_user_idx=-1) -%}
{%- for i in range(loop_messages | length) -%}
    {%- if loop_messages[i]['role'] == 'user' -%}
        {%- set ns_turn.last_user_idx = i -%}
    {%- endif -%}
{%- endfor -%}

{#- Loop through messages -#}
{%- for message in loop_messages -%}
    {%- if message['role'] != 'tool' -%}
    {%- set ns.prev_message_type = None -%}
    {%- set role = 'model' if message['role'] == 'assistant' else message['role'] -%}
    {#- Detect continuation: suppress duplicate <|turn>model when previous non-tool message was also assistant -#}
    {%- set prev_nt = namespace(role=None, found=false) -%}
    {%- if loop.index0 > 0 -%}
        {%- for j in range(loop.index0 - 1, -1, -1) -%}
            {%- if not prev_nt.found -%}
                {%- if loop_messages[j]['role'] != 'tool' -%}
                    {%- set prev_nt.role = loop_messages[j]['role'] -%}
                    {%- set prev_nt.found = true -%}
                {%- endif -%}
            {%- endif -%}
        {%- endfor -%}
    {%- endif -%}
    {%- set continue_same_model_turn = (role == 'model' and prev_nt.role == 'assistant') -%}
    {%- if not continue_same_model_turn -%}
        {{- '<|turn>' + role + '\n' }}
    {%- endif -%}

    {#- Render reasoning/reasoning_content as thinking channel -#}
    {%- set thinking_text = message.get('reasoning') or message.get('reasoning_content') -%}
    {%- if thinking_text and loop.index0 > ns_turn.last_user_idx and message.get('tool_calls') -%}
        {{- '<|channel>thought\n' + thinking_text + '\n<channel|>' -}}
    {%- endif -%}

            {%- if message['tool_calls'] -%}
                {%- for tool_call in message['tool_calls'] -%}
                    {%- set function = tool_call['function'] -%}
                    {{- '<|tool_call>call:' + function['name'] + '{' -}}
                    {%- if function['arguments'] is mapping -%}
                        {%- set ns_args = namespace(found_first=false) -%}
                        {%- for key, value in function['arguments'] | dictsort -%}
                            {%- if ns_args.found_first %},{% endif -%}
                            {%- set ns_args.found_first = true -%}
                            {{- key -}}:{{- format_argument(value, escape_keys=False) -}}
                        {%- endfor -%}
                    {%- elif function['arguments'] is string -%}
                        {{- function['arguments'] -}}
                    {%- endif -%}
                    {{- '}<tool_call|>' -}}
                {%- endfor -%}
                {%- set ns.prev_message_type = 'tool_call' -%}
            {%- endif -%}

            {%- set ns_tr_out = namespace(flag=false) -%}
            {%- if message.get('tool_responses') -%}
                {#- Legacy: tool_responses embedded on the assistant message (Google/Gemma native) -#}
                {%- for tool_response in message['tool_responses'] -%}
                    {{- format_tool_response_block(tool_response['name'] | default('unknown'), tool_response['response']) -}}
                    {%- set ns_tr_out.flag = true -%}
                    {%- set ns.prev_message_type = 'tool_response' -%}
                {%- endfor -%}
            {%- elif message.get('tool_calls') -%}
                {#- OpenAI Chat Completions: forward-scan consecutive role:tool messages -#}
                {%- set ns_tool_scan = namespace(stopped=false) -%}
                {%- for k in range(loop.index0 + 1, loop_messages | length) -%}
                    {%- if ns_tool_scan.stopped -%}
                    {%- elif loop_messages[k]['role'] != 'tool' -%}
                        {%- set ns_tool_scan.stopped = true -%}
                    {%- else -%}
                        {%- set follow = loop_messages[k] -%}
                        {#- Resolve tool_call_id to function name -#}
                        {%- set ns_tname = namespace(name=follow.get('name') | default('unknown')) -%}
                        {%- for tc in message['tool_calls'] -%}
                            {%- if tc.get('id') == follow.get('tool_call_id') -%}
                                {%- set ns_tname.name = tc['function']['name'] -%}
                            {%- endif -%}
                        {%- endfor -%}
                        {#- Handle content as string or content-parts array -#}
                        {%- set tool_body = follow.get('content') -%}
                        {%- if tool_body is string -%}
                            {{- format_tool_response_block(ns_tname.name, tool_body) -}}
                        {%- elif tool_body is iterable and tool_body is not string -%}
                            {%- set ns_txt = namespace(s='') -%}
                            {%- for part in tool_body -%}
                                {%- if part.get('type') == 'text' -%}
                                    {%- set ns_txt.s = ns_txt.s + (part.get('text') | default('')) -%}
                                {%- endif -%}
                            {%- endfor -%}
                            {{- format_tool_response_block(ns_tname.name, ns_txt.s) -}}
                            {%- for part in tool_body -%}
                                {%- if part.get('type') == 'image' -%}
                                    {{- '<|image|>' -}}
                                {%- elif part.get('type') == 'audio' -%}
                                    {{- '<|audio|>' -}}
                                {%- elif part.get('type') == 'video' -%}
                                    {{- '<|video|>' -}}
                                {%- endif -%}
                            {%- endfor -%}
                        {%- else -%}
                            {{- format_tool_response_block(ns_tname.name, tool_body) -}}
                        {%- endif -%}
                        {%- set ns_tr_out.flag = true -%}
                        {%- set ns.prev_message_type = 'tool_response' -%}
                    {%- endif -%}
                {%- endfor -%}
            {%- endif -%}

            {%- set captured_content -%}
            {%- if message['content'] is string -%}
                {%- if role == 'model' -%}
                    {{- strip_thinking(message['content']) -}}
                {%- else -%}
                    {{- message['content'] | trim -}}
                {%- endif -%}
            {%- elif message['content'] is iterable -%}
                {%- for item in message['content'] -%}
                    {%- if item['type'] == 'text' -%}
                        {%- if role == 'model' -%}
                            {{- strip_thinking(item['text']) -}}
                        {%- else -%}
                            {{- item['text'] | trim -}}
                        {%- endif -%}
                    {%- elif item['type'] == 'image' -%}
                        {{- '<|image|>' -}}
                        {%- set ns.prev_message_type = 'image' -%}
                    {%- elif item['type'] == 'audio' -%}
                        {{- '<|audio|>' -}}
                        {%- set ns.prev_message_type = 'audio' -%}
                    {%- elif item['type'] == 'video' -%}
                        {{- '<|video|>' -}}
                        {%- set ns.prev_message_type = 'video' -%}
                    {%- endif -%}
                {%- endfor -%}
            {%- endif -%}
            {%- endset -%}

            {{- captured_content -}}
            {%- set has_content = captured_content | trim | length > 0 -%}

        {%- if ns.prev_message_type == 'tool_call' and not ns_tr_out.flag -%}
            {{- '<|tool_response>' -}}
        {%- elif not (ns_tr_out.flag and not has_content) -%}
            {{- '<turn|>\n' -}}
        {%- endif -%}
    {%- endif -%}
{%- endfor -%}

{%- if add_generation_prompt -%}
    {%- if ns.prev_message_type != 'tool_response' and ns.prev_message_type != 'tool_call' -%}
        {{- '<|turn>model\n' -}}
        {%- if not enable_thinking | default(false) -%}
            {{- '<|channel>thought\n<channel|>' -}}
        {%- endif -%}
    {%- endif -%}
{%- endif -%}
"""# + "\n"
}
