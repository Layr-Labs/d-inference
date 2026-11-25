from pathlib import Path

REMOTE = Path('/Users/developer/DarkbloomDev/qwen-mtp-accepted-qualification-20260920/reference')
NATIVE_DIRECTORY = Path('/Users/developer/DarkbloomDev/qwen-mtp-accepted-qualification-20260920/native')
MODEL_DIRECTORY = Path('/Users/developer/DarkbloomDev/models/Qwen3.5-9B')
REQUEST_ID = '9e6f732e-2be0-49eb-a01a-ef9ebebcb619'


def require_short(job):
    expected = dict(registered_model='registered_qwen35_9b', request_id=REQUEST_ID,
                    prompt_count=32, chunk_size=16, output_count=8, stage_cut=4,
                    stop_token_ids=[], native_seconds=300, parent_seconds=315,
                    deployment=str(NATIVE_DIRECTORY), model_dir=str(MODEL_DIRECTORY),
                    prompt_file=str(REMOTE / 'inputs/prompt.ids.json'), run_dir=str(REMOTE / 'runs/reference-1'))
    if any(type(job.get(k)) is not type(v) or job[k] != v for k, v in expected.items()):
        raise ValueError('This invocation is only the pinned short ordinary 9B reference')
