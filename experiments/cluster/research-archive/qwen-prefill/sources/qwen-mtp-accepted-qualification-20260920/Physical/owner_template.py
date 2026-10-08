"""Reuse the qualified owner/controller, resource monitor and alias-retirement parent."""
import base64
import json
from pathlib import Path
from common import BASE, OWNER, REMOTE, canonical, replace, sha, write, write_json


def stage(output, binding, mode, tokens):
    target = output / mode; remote = REMOTE + '/' + mode
    old = BASE / 'templates/owner'
    exact = ['lease_source.py', 'parent_cleanup.py', 'monitor.py', 'reference_resources.py',
             'stage_checks/__init__.py', 'stage_checks/common.py', 'configuration/matrix.json', 'owner-bundle.json']
    for name in exact:
        write(target / name, (old / name).read_bytes())
    text = (old / 'parent_settings.py').read_text()
    text = replace(text, "'/usr/bin/ssh', '-T',", "'/usr/bin/ssh', '-T', '-S', 'none',")
    write(target / 'parent_settings.py', text.encode())
    text = (old / 'run_physical.py').read_text()
    text = replace(text, "REMOTE = '/Users/developer/DarkbloomDev/owner-native-mtp-probe-clean-20260915'", 'REMOTE = ' + repr(remote))
    text = replace(text, "sample.get('admissible') is not True:", "sample.get('admissible') is not True or sample.get('pressureLevel') != 1:")
    text = replace(text, "CONTROLLER = BASE / 'controls/owner-controller'", 'CONTROLLER = Path(' + repr(str(OWNER / 'controls/owner-controller')) + ')')
    text = replace(text, "(ROOT.parent / 'machines/CREDENTIALS.private.md')", "Path('/Users/developer/DarkbloomDev/machines/CREDENTIALS.private.md')")
    write(target / 'run_physical.py', text.encode())
    postflight = '''"""Read-only owned-generation observation; no signal or journal mutation."""
import json,shlex,subprocess
from parent_settings import SSH
REMOTE=@REMOTE@
def postflight(host, remote_run=None, timeout=15):
    if remote_run is not None or not 0<timeout<=15: raise ValueError('Closed postflight scope')
    command=['/usr/bin/python3','-B',REMOTE+'/collect_owner.py','observe']
    result=subprocess.run(SSH+[host,shlex.join(command)],capture_output=True,timeout=timeout,check=True)
    if result.stderr or len(result.stdout)>65536: raise ValueError('Bounded postflight output differs')
    return json.loads(result.stdout)
'''.replace('@REMOTE@', repr(remote))
    write(target / 'probe_postflight.py', postflight.encode())
    collector = (BASE / 'collect_owner.py').read_text().replace('@MODE@', mode).replace('@REQUEST_ID@', binding['requestID']).replace('@DIRECTORY@', remote)
    write(target / 'collect_owner.py', collector.encode())
    expected = binding[mode + 'Agreement']; cluster = 'qwen9b-accepted-' + mode
    setup = json.loads((old / 'configuration/controller.json').read_bytes())
    template = json.loads(base64.b64decode(setup['readyTemplateBase64']))
    for peer in template['ready']['identity']['peers']:
        peer['buildSHA256'] = binding['workerSHA256']
    setup.update(clusterID=cluster, membershipEpoch=expected['membershipEpoch'], requestID=binding['requestID'],
                 promptTokenIDs=tokens, outputCount=8, chunkSize=16, stopTokenIDs=[], expectedTokenIDs=None,
                 readyTemplateBase64=base64.b64encode(canonical(template)).decode())
    for peer in setup['peers']:
        peer['installedOwner'] = remote + '/darkbloom-owner-qualification'
    write_json(target / 'configuration/controller.json', setup)
    for rank in (0, 1):
        owner = json.loads((old / ('configuration/owner-rank' + str(rank) + '.json')).read_bytes())
        ready = json.loads(base64.b64decode(owner['readyTemplateBase64']))
        for peer in ready['ready']['identity']['peers']:
            peer['buildSHA256'] = binding['workerSHA256']
        owner.update(clusterID=cluster, workerExecutable=REMOTE + '/native/darkbloom-cluster-worker',
                     readyTemplateBase64=base64.b64encode(canonical(ready)).decode())
        owner['workerEnvironment'].update(DARKBLOOM_PRIVATE_QWEN_MTP_MODE=mode,
            DARKBLOOM_BENCHMARK_EVIDENCE_DIR=remote + '/evidence', JACCL_IBV_DEVICES=remote + '/matrix.json')
        write_json(target / ('configuration/owner-rank' + str(rank) + '.json'), owner)
    pins = [dict(path=str(p), sha256=sha(p)) for p in sorted(target.rglob('*')) if p.is_file()]
    # Control bytes are observed here and required against retained metadata by
    # bind.py before this function; neither helper is rebuilt or replaced.
    for p in [OWNER / 'controls/owner-controller', OWNER / 'configuration/known_hosts', output / 'expected.json']:
        pins.append(dict(path=str(p), sha256=sha(p)))
    write_json(target / 'run-pins.json', dict(files=pins))
    return target
