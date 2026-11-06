"""Collect exact original sidecars and join numerical, owner, resource and alias evidence."""
import argparse
import json
from pathlib import Path
import shlex
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Physical'))

from common import BASE, REMOTE, local_execute, sha, verify_bound, verify_sources, write, write_json
from results import controller, copies, parent, pinned_json, reference_result, resources
sys.path.insert(0, str(BASE.parent / 'Compare'))
from accepted_rounds import check_rounds
from accepted_target import compare as compare_accepted
from audit_candidate import compare as compare_ordinary
from audit_common import exact, parse, request_context
from audit_reference import check_reference
from audit_scope import AuditScope
from recorded_math import digest, require
from snapshot import snapshot


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--bound', required=True, type=Path)
    parser.add_argument('--binding-sha256', required=True)
    parser.add_argument('--mode', required=True, choices=['off','depth1'])
    for name in ['run-result','reference-result','reference-stdout','copy0','copy1']:
        parser.add_argument('--' + name, required=True, type=Path)
        parser.add_argument('--' + name + '-sha256', required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args(); verify_sources(); verify_bound(args.bound, args.binding_sha256)
    binding = json.loads((args.bound / 'expected.json').read_bytes())
    prior = reference_result(args.reference_result, args.reference_result_sha256, binding)
    copied = copies([args.copy0,args.copy1], [args.copy0_sha256,args.copy1_sha256], args.binding_sha256)
    run = pinned_json(args.run_result, args.run_result_sha256)
    for key, value in dict(schema='qwen_mtp_owned_pair_run_v1', status='passed', mode=args.mode,
                           bindingSHA256=args.binding_sha256, referenceResultSHA256=args.reference_result_sha256).items():
        exact(run[key], value, 'Actual originating run')
    parent_path = args.bound / args.mode / 'physical-1/execution.json'
    exact(run['parentExecution'], str(parent_path), 'Exact original parent namespace')
    execution = parent(parent_path, run['parentExecutionSHA256'])
    context = request_context((args.bound / 'prompt.ids.json').read_bytes(), binding['requestID'], AuditScope('registered_qwen35_9b',32,16,8,4))
    full_item = snapshot(args.reference_stdout, 32*1024**2)
    exact(full_item['sha256'], args.reference_stdout_sha256, 'Previously collected reference stdout')
    reference = check_reference(full_item['raw'], context)
    exact(reference['selected'], prior['selectedTokenIDs'], 'Actual reference result tokens')
    exact(reference['execution']['finalLogits']['logicalBytesSHA256'], prior['finalLogitsSHA256'], 'Actual full row result')
    exact(reference['execution']['finalState']['fingerprint'], prior['finalStateFingerprint'], 'Actual full state result')
    controller(parent_path.parent / 'controller.stdout.jsonl', args.bound / args.mode / 'configuration/controller.json',
               args.mode, binding, reference['selected'])
    observations = resources(parent_path.parent, args.bound / 'reference/package')
    if not args.output.is_absolute() or args.output != args.output.resolve() or args.output.exists():
        raise ValueError('Fresh canonical collection output required')
    args.output.mkdir(mode=0o700); execute = local_execute(args.bound)
    setup = json.loads((args.bound / args.mode / 'configuration/controller.json').read_bytes())
    actual = []; retained = []
    for rank, peer in enumerate(setup['peers']):
        command = ['/usr/bin/ssh','-T','-S','none','-p',str(peer['port']),'-i',peer['identityFile'],
            '-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes',
            '-o','UserKnownHostsFile='+peer['knownHostsFile'],'-o','ConnectTimeout=5',peer['user']+'@'+peer['host'],
            shlex.join(['/usr/bin/python3','-B',REMOTE+'/'+args.mode+'/collect_owner.py','collect'])]
        name = 'rank' + str(rank)
        code = execute(command,args.output,name,30,cap=17*1024**2)
        require(code == 0 and (args.output/(name+'.stderr')).stat().st_size == 0, 'Actual collection failed')
        packet = snapshot(args.output/(name+'.stdout'),17*1024**2)['raw']
        head, sep, raw = packet.partition(b'\n')
        require(sep and len(head)<=65536 and 0<len(raw)<=16*1024**2, 'Bounded complete collection packet')
        header=parse(head)
        for key,value in dict(schema='mtp_owned_evidence_collection_v1',mode=args.mode,requestID=binding['requestID'],
            ownerConfigurationSHA256=sha(args.bound/args.mode/('configuration/owner-rank'+str(rank)+'.json'))).items():
            exact(header[key],value,'Collected owner identity')
        obs=header['observation']; exact(obs['active'],[],'No current native/owner'); exact(obs['journalBytes'],0,'Empty canonical journal')
        before=copied[rank]['journal']; after=obs['journal']
        exact(after['identity'][:2],[before['device'],before['inode']],'Same original canonical journal inode')
        exact(after['bytes'],0,'Canonical empty inode'); exact(after['sha256'],digest(b''),'Canonical empty bytes')
        side=obs['sidecar']; exact(side['bytes'],len(raw),'Sidecar full length'); exact(side['sha256'],digest(raw),'Sidecar full hash')
        exact(side,execution['remoteCleanup']['postflight'][rank]['sidecar'],'Original terminal to collection sidecar identity/hash')
        exact(obs['journal']['identity'][:3],execution['remoteCleanup']['postflight'][rank]['journal']['identity'][:3],'Original retirement journal identity')
        write(args.output/(name+'.json'),raw); write_json(args.output/(name+'-header.json'),header)
        actual.append(parse(raw)); retained.append(dict(rank=rank,path=str(args.output/(name+'.json')),sha256=digest(raw)))
    if args.mode=='off':
        numerical=compare_ordinary(reference,actual,binding['offAgreement'],context); rounds=None
    else:
        targets,rounds=check_rounds(actual,context,reference['selected'],binding['depth1Agreement'])
        numerical=compare_accepted(reference,targets,binding['depth1Agreement'],context)
    final_item = snapshot(args.reference_stdout,32*1024**2,keep=False)
    exact({k:v for k,v in final_item.items() if k!='raw'},{k:v for k,v in full_item.items() if k!='raw'},'Reference bytes unchanged')
    parent(parent_path,run['parentExecutionSHA256']); verify_bound(args.bound,args.binding_sha256); verify_sources()
    write_json(args.output/'pair-result.json',dict(schema='qwen_mtp_owned_pair_result_v1',status='passed',mode=args.mode,
        bindingSHA256=args.binding_sha256,runResultSHA256=args.run_result_sha256,referenceResultSHA256=args.reference_result_sha256,
        referenceStdoutSHA256=args.reference_stdout_sha256,selectedTokenIDs=reference['selected'],
        numerical=numerical,rounds=rounds,sidecars=retained,resources=observations,
        exactReferenceNumericalComparisonPassed=True,ownedCleanupAndAliasVerified=True,
        encryptedTransportQualified=False,throughputMeasurementValid=False,servingEnabled=False,
        correctedCollectorSHA256=sha(Path(__file__).resolve())))


if __name__=='__main__':
    main()
