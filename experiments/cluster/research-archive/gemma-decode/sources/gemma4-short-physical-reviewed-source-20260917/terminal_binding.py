"""Join original SSH-delivered terminal digests to later collected exact bytes."""
from pathlib import Path
from binding_common import fields, parse, pin, require, same
from binding_inputs import snapshot


def describe_launch(path,mode):
    require(mode in ('full','stages'),'Unknown launch cohort')
    modes=['full'] if mode=='full' else ['stage0','stage1']
    path=Path(path);require(path.is_absolute() and path.parent.resolve()==path.parent,'Canonical launch receipt')
    item=snapshot(path,1_048_576);value=parse(item['raw'])
    same(value['status'],'completed','Successful original SSH launch')
    same(value['exitCodes'],[0]*len(modes),'Original SSH exits')
    same(value['cleanupErrors'],[],'Original SSH cleanup')
    require(value['reaped'] is True and value['outputComplete'] is True and value['watchdogExpired'] is False
            and 'cleanupFailure' not in value,'Incomplete original launch')
    require(type(value['results']) is list and len(value['results'])==len(modes),'Remote result coverage')
    remote={}
    for wanted,row in zip(modes,value['results']):
        fields(row,'mode status terminalSHA256','Original remote result')
        same(row['mode'],wanted,'Original remote role/order');same(row['status'],'completed','Original remote completion')
        remote[wanted]=pin(row['terminalSHA256'])
    return dict(path=str(path),sha256=item['sha256'],remoteTerminalSHA256=remote)


def recheck_launch(reference,mode):
    fields(reference,'path sha256 remoteTerminalSHA256','Pinned launch receipt')
    same(describe_launch(reference['path'],mode),reference,'Original launch receipt changed')


def require_terminal(reference,mode,collected_sha256):
    require(mode in reference['remoteTerminalSHA256'],'Collected role not launched')
    same(pin(collected_sha256),reference['remoteTerminalSHA256'][mode],'Collected terminal differs from original SSH result')
