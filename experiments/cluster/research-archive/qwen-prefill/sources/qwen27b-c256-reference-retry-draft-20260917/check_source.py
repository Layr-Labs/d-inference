"""Small source/pin/inverse checks only; no preparation or execution."""
import ast
import json
from retry_inputs import BASE, OLD, OLD_LAUNCH, NEW_LAUNCH, OLD_RUN, NEW_RUN, read, pin, require, verify_source, expected_packet


def main():
    verify_source()
    job, _ = expected_packet()
    for name in ('retry_inputs.py', 'prepare.py', 'bind_cases.py', 'review_reference.py', 'check_source.py'):
        ast.parse(read(BASE/name))
    runner = read(OLD/'run_physical.py').decode()
    require(runner.count(OLD_LAUNCH) == runner.count(OLD_RUN) == 1, 'Original runner path preimages differ')
    require(read(OLD/'install_new_tree.py').decode().count(OLD_LAUNCH) == 1, 'Installer root preimage differs')
    require(runner.count(pin(OLD/'package/manifest.json')['sha256']) == 2
            and runner.count(pin(OLD/'package/example-job.json')['sha256']) == 1, 'Runner pin preimages differ')
    require(NEW_LAUNCH != OLD_LAUNCH and NEW_RUN != OLD_RUN, 'Retry must use new remote paths')
    require(job['native_sha256'] == 'd71726f61ff5cef6c2a7722b0a06fb7d6b7c61af2cb081ff3aef083803f32aac',
            'Existing actual native changed')
    print(json.dumps(dict(sourceChecksComplete=True,prepared=False,compilerOrModelOrRemoteExecuted=False,
        jobSHA256=pin(BASE/'reference-job.json')['sha256'],onlyReferenceJobDelta=['prompt_file','run_dir']),sort_keys=True))


if __name__ == '__main__':
    main()
