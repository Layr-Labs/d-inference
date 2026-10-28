"""Validate native selected-token/frontier metadata; no numerical comparison."""
import hashlib
from binding_common import fields, integer, pin, require, same


def validate_completion(execution, expected):
    selected = execution['selectedTokenIDs']
    requested = expected['requestedOutputCount']
    stops = expected['stopTokenIDs']
    require(type(selected) is list and 1 <= len(selected) <= requested, 'Invalid actual selected token count')
    for token in selected:
        integer(token, 'selected token', 0, 248319)
    require(not any(token in stops for token in selected[:-1]), 'Generation continued beyond an earlier stop token')
    if execution['finishReason'] == 'eos':
        require(selected[-1] in stops, 'EOS token is not an admitted stop')
    else:
        same(execution['finishReason'], 'length', 'finish reason')
        require(len(selected) == requested and selected[-1] not in stops, 'Length completion differs from output limit or masks EOS')
    digest = hashlib.sha256(','.join(map(str, selected)).encode()).hexdigest()
    same(execution['selectedTokenIDsSHA256'], digest, 'selected token list hash')
    prefill = (expected.prompt_count - 1) // expected.chunk_size + 1
    frontier = expected.prompt_count + len(selected) - 1
    same(execution['completedFrames'], prefill + len(selected) - 1, 'completed frames')
    same(execution['committedTokens'], frontier, 'actual committed frontier')
    require(type(execution['tokens']) is list and len(execution['tokens']) == len(selected), 'Incomplete per-token evidence')
    for index, evidence in enumerate(execution['tokens']):
        fields(evidence, 'outputOrdinal frame committedTokens tokenID maximumTieCount maximumLogit '
               'logitsShape logitsDType logitsByteCount logitsLogicalBytesSHA256 policy cpuCrosscheckPolicy '
               'nativeSelectionMatchesCapturedFullRow', 'token evidence')
        offset = (prefill - 1) * expected.chunk_size if index == 0 else expected.prompt_count + index - 1
        frame = dict(sequence=prefill + index - 1, phase='prefill' if index == 0 else 'decode',
                     tokenOffset=offset, tokenCount=expected.prompt_count-offset if index == 0 else 1,
                     finalPromptChunk=index == 0)
        values = dict(outputOrdinal=index, frame=frame, committedTokens=expected.prompt_count + index,
            tokenID=selected[index], logitsShape=[1, 248320], logitsDType='bfloat16', logitsByteCount=496640,
            policy='mlx_argmax_all_axes_with_finite_guard_v1',
            cpuCrosscheckPolicy='finite_maximum_lowest_vocabulary_index_v1', nativeSelectionMatchesCapturedFullRow=True)
        for key, value in values.items():
            same(evidence[key], value, 'token.' + key)
        integer(evidence['maximumTieCount'], 'maximum tie count', 1, 248320)
        require(type(evidence['maximumLogit']) in (int, float), 'Invalid reported maximum logit')
        pin(evidence['logitsLogicalBytesSHA256'])
    return frontier
