"""Render the exact artifact and operator qualification steps for Actions."""
import json

from .evidence import LANES, required_checks


def summary(root, env, bundle_name):
    payload = json.loads((root / 'release-payload.json').read_text())
    request_text = (root / 'qualification-request.json').read_text().strip()
    artifact_name = env.get('PUBLICATION_ARTIFACT') or bundle_name
    # A resume run describes the run that signed these bytes, not itself.
    source_run = env.get('SOURCE_RUN_ID') or env['GITHUB_RUN_ID']
    source_sha = env.get('SOURCE_SHA') or env['GITHUB_SHA']
    run_url = f"https://github.com/{env['GITHUB_REPOSITORY']}/actions/runs/{source_run}"

    lines = [
        '## Waiting for independent build qualification', '',
        f"Artifact `{artifact_name}` from source commit `{source_sha}`, "
        f"run [{source_run}]({run_url})"
        + ('' if env.get('SOURCE_RUN_ID', env['GITHUB_RUN_ID']) != env['GITHUB_RUN_ID']
           else f" attempt {env['GITHUB_RUN_ATTEMPT']}") + '.', '',
        '| digest | value |', '| --- | --- |',
        f"| binary | `{payload['binary_hash']}` |",
        f"| bundle | `{payload['bundle_hash']}` |",
        f"| metallib | `{payload['metallib_hash']}` |",
        f"| code directory | `{payload['code_directory_hash']}` |", '',
        '`qualification-request.json`:', '', '```json', request_text, '```', '',
        'Required checks (recorded once each lane validator uploads its result JSON):',
    ]
    for lane in LANES:
        for check in required_checks(lane):
            lines.append(f'- {lane}: `{check}` — not yet run')
    lines += [
        '', 'Run each lane validator against the retained publication directory:', '', '```bash',
        'python3 scripts/provider-release-qualify.py --directory <dir> --lane macos-27 '
        '--level static,smoke,live --output qualification-result-macos-27.json',
        'python3 scripts/provider-release-qualify.py --directory <dir> --lane older-macos '
        '--level static,smoke,live --output qualification-result-older-macos.json',
        '```', '', 'Render the operator evidence from both result files:', '', '```bash',
        'python3 scripts/provider-release-publication.py evidence --directory <dir> '
        '--result qualification-result-macos-27.json --result qualification-result-older-macos.json',
        '```', '', 'Submit the completed template for durable review recording (see '
        'docs/operations/app-attest-build-qualification.md step 3):', '', '```bash',
        'curl --fail-with-body --request POST "$COORDINATOR_URL/v1/admin/app-attest/builds" \\',
        '  --header "Authorization: Bearer $DARKBLOOM_ADMIN_TOKEN" \\',
        "  --header 'Content-Type: application/json' \\",
        '  --data-binary @qualification-request.json', '```',
    ]
    text = '\n'.join(lines) + '\n'

    step_summary = env.get('GITHUB_STEP_SUMMARY')
    if step_summary:
        with open(step_summary, 'a') as fh:
            fh.write(text)
    else:
        print(text)
    print('::notice::Publication staged; awaiting independent build qualification before registration')


