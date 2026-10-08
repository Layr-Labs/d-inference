from pathlib import Path

REMOTE = Path('/Users/developer/DarkbloomDev/qwen9b-protected-reference-20260917')
NATIVE_DIRECTORY = Path('/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915/native-aligned-payload')
MODEL_DIRECTORY = Path('/Users/developer/DarkbloomDev/models/Qwen3.5-9B')
REQUEST_ID = 'f6a06d14-9138-4a19-aece-39207e1c874e'


def require_short(job):
    expected = dict(registered_model='registered_qwen35_9b', request_id=REQUEST_ID,
                    prompt_count=32, chunk_size=16, output_count=2, stage_cut=16,
                    stop_token_ids=[], native_seconds=300, parent_seconds=315,
                    deployment=str(NATIVE_DIRECTORY), model_dir=str(MODEL_DIRECTORY),
                    prompt_file=str(REMOTE / 'inputs/prompt.ids.json'), run_dir=str(REMOTE / 'runs/reference-1'))
    if any(type(job.get(k)) is not type(v) or job[k] != v for k, v in expected.items()):
        raise ValueError('This invocation is only the pinned short ordinary 9B reference')
