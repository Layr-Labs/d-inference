"""Bind a resumed workflow to a retained artifact from its source run."""
import json
import subprocess


def resume_source(env, run_id):
    repo = env['GITHUB_REPOSITORY']
    run_result = subprocess.run(['gh', 'api', f'repos/{repo}/actions/runs/{run_id}'],
                                 capture_output=True, text=True, check=True)
    run_info = json.loads(run_result.stdout)
    if run_info.get('path') != '.github/workflows/release-swift.yml':
        raise ValueError('resume-source: run does not belong to release-swift.yml')
    sha = env['GITHUB_SHA']
    if run_info.get('head_sha') != sha:
        raise ValueError('resume-source: run head_sha does not match GITHUB_SHA')

    # The repository is already pinned by the API path above, so a match here
    # implies the same repository; nothing else to cross-check on that axis.
    artifacts_result = subprocess.run(
        ['gh', 'api', f'repos/{repo}/actions/runs/{run_id}/artifacts', '--paginate'],
        capture_output=True, text=True, check=True)
    # gh --paginate emits one JSON object per page. Decode each page without
    # assuming the retained artifacts fit in the first response.
    remaining = artifacts_result.stdout.lstrip()
    decoder = json.JSONDecoder()
    artifacts = []
    while remaining:
        page, end = decoder.raw_decode(remaining)
        artifacts.extend(page.get('artifacts', []))
        remaining = remaining[end:].lstrip()
    prefix = f'provider-publication-{sha}-'
    candidates = []
    for artifact in artifacts:
        name = artifact.get('name', '')
        if artifact.get('expired') or not name.startswith(prefix):
            continue
        suffix = name[len(prefix):]
        if suffix.isdigit():
            candidates.append((int(suffix), name))
    if not candidates:
        raise ValueError(f'resume-source: no non-expired publication artifact found for {sha}')
    _, artifact_name = max(candidates)

    with open(env['GITHUB_OUTPUT'], 'a') as fh:
        fh.write(f'source_run_id={run_id}\n')
        fh.write(f'source_sha={sha}\n')
        fh.write(f'publication_artifact={artifact_name}\n')

