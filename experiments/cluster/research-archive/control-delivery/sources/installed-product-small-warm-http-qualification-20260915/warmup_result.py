"""Warmup eligibility is separate from the unchanged external-content SLA result."""
import hashlib
import json
from warmup_inputs import bounded_bytes


def validate(receipt, expected_tokens, prompt_sha256, exit_code):
    def require(condition, message):
        if not condition:
            raise ValueError(message + '; measured request not sent')

    require(type(expected_tokens) is int and expected_tokens in (512, 1024), 'Wrong warmup geometry')
    require(receipt.get('schema') == 'installed_external_content_client_v1', 'Unknown client receipt')
    require(receipt.get('model') == 'Qwen3.5-9B'
            and receipt.get('prompt_utf8_sha256') == prompt_sha256, 'Wrong warmup input')
    settings = dict(max_tokens=128, enable_thinking=False, reasoning_parser='qwen3',
                    temperature=0, top_p=1, top_k=0, repetition_penalty=1,
                    presence_penalty=0, frequency_penalty=0)
    require(receipt.get('request_settings') == settings, 'Warmup request settings differ')
    require(type(receipt.get('http_status')) is int and receipt['http_status'] == 200
            and receipt.get('capture_complete') is True, 'Incomplete HTTP capture')
    require(not receipt.get('cleanup_errors') and not receipt.get('capture_error'), 'Client cleanup/capture failed')
    measurement = receipt.get('measurement', {})
    require(measurement.get('stream_terminal_complete') is True
            and measurement.get('done') is True, 'Missing complete terminal stream')
    require(type(measurement.get('declared_prompt_tokens')) is int
            and measurement['declared_prompt_tokens'] == expected_tokens
            and type(measurement.get('requested_output_tokens')) is int
            and measurement['requested_output_tokens'] == 128, 'Wrong declared token count')
    usage = measurement.get('usage')
    require(type(usage) is dict and set(usage) == {'prompt_tokens', 'completion_tokens', 'total_tokens'}
            and all(type(x) is int for x in usage.values()), 'Invalid terminal usage')
    require(usage['prompt_tokens'] == expected_tokens
            and 1 <= usage['completion_tokens'] <= 128
            and usage['total_tokens'] == expected_tokens + usage['completion_tokens'], 'Warmup usage differs')
    finish = measurement.get('finish_reason')
    require(finish == 'stop' or (finish == 'length' and usage['completion_tokens'] == 128), 'Invalid warmup finish')
    status = receipt.get('status')
    if status == 'no_content':
        require(receipt.get('error') == {'type': 'ClientOutcome', 'code': 'no_content'}
                and measurement.get('first_content_ns') is None and finish == 'stop',
                'No-content result is not an EOS-compatible complete stop')
    else:
        require(status in ('completed', 'content_deadline_missed') and receipt.get('error') is None,
                'Warmup transport/stream failed')
        require(type(measurement.get('first_content_ns')) is int and measurement['first_content_ns'] >= 0,
                'Missing content observation')
    require(type(exit_code) is int and exit_code == (0 if status == 'completed' else 1), 'Client exit/receipt mismatch')
    return dict(eligible=True, actualUsage=usage, finishReason=finish,
                normalClientStatus=status, normalClientExitCode=exit_code,
                normalClientPassed=status == 'completed', contentSLA=measurement.get('content_sla'),
                eosTokenDirectlyObserved=False, gpuExecutionIndependentlyObserved=False,
                nativeRetirementProvenByHTTP=False)


def read(directory, expected_tokens, prompt_path, exit_code):
    receipt_raw = bounded_bytes(directory / 'receipt.json', 65536)
    receipt = json.loads(receipt_raw)
    result = validate(receipt, expected_tokens,
                      hashlib.sha256(bounded_bytes(prompt_path, 262144)).hexdigest(), exit_code)
    result['receiptSHA256'] = hashlib.sha256(receipt_raw).hexdigest()
    return result
