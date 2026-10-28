#!/usr/bin/env python3
"""CPU-only comparison to retained pre-change Python; no candidate/model IO."""
import argparse
import importlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from unittest.mock import Mock,patch

ROOT=Path(__file__).resolve().parent
PROPOSED=ROOT/'proposed/experiments/cluster'
sys.path.insert(0,str(PROPOSED))
from runtime.stage_checks import configuration,evidence,inputs,ranks,storage
from runtime.stage_checks.common import canonical,digest
from stage_cut_test_support import EPOCH,context,reports,states


def originals():
    name='_short_cut_original_runtime';folder=ROOT/'originals/experiments/cluster/runtime'
    spec=importlib.util.spec_from_file_location(name,folder/'__init__.py',submodule_search_locations=[str(folder)])
    module=importlib.util.module_from_spec(spec);sys.modules[name]=module;spec.loader.exec_module(module)
    return {part:importlib.import_module(name+'.stage_checks.'+part) for part in ('configuration','evidence','inputs','ranks','storage')}


def main():
    guards=[patch(name,side_effect=AssertionError('Real subprocess/socket forbidden')) for name in ('subprocess.run','subprocess.Popen','socket.socket')]
    for guard in guards:guard.start()
    try:
        old=originals();ctx=context();rows=reports(ctx);checks=[]
        for rank in (0,1):
            args=(rank,EPOCH,ctx,'/unused-bundle','c'*64,[['127.0.0.1:31001'],['127.0.0.1:31002']],180)
            assert canonical(old['configuration'].build(*args))==canonical(configuration.build(*args))
            checks.append('rank'+str(rank)+' default configuration bytes')
            for tokens in (32,64,65,66,67,68):
                entries,_,_=states(ctx,rank,tokens)
                args=(entries,ctx['text'],rank,tokens)
                assert canonical(old['evidence'].state_entries(*args))==canonical(evidence.state_entries(*args))
                checks.append('rank'+str(rank)+' state '+str(tokens))
            old['ranks'].validate(rows[rank],rank,EPOCH,ctx);ranks.validate(rows[rank],rank,EPOCH,ctx)
        assert canonical(old['ranks'].pair(rows,ctx))==canonical(ranks.pair(rows,ctx));checks.append('paired validation result bytes')
        loads=[row['sourceLoad'] for row in rows]
        assert canonical(old['storage'].validate_pair(loads,ctx))==canonical(storage.validate_pair(loads,ctx));checks.append('storage validation result bytes')
        with tempfile.TemporaryDirectory() as temporary:
            folder=Path(temporary);model=folder/'model';model.mkdir();raw=canonical(ctx['configuration'])
            (model/'config.json').write_bytes(raw)
            (model/'manifest.json').write_bytes(canonical(dict(aggregate_sha256=ctx['artifact'],total_size_bytes=len(raw),files=[dict(path='config.json',sha256=digest(raw))])))
            prompt=folder/'prompt.json';teacher=folder/'teacher.json'
            prompt.write_bytes(canonical(ctx['request']['promptTokenIDs']));teacher.write_bytes(canonical(ctx['request']['teacherTokenIDs']))
            args=argparse.Namespace(command='ranks',model_dir=model,artifact_aggregate_sha256=ctx['artifact'],tokens_file=prompt,
                tokens_sha256=None,teacher_tokens_file=teacher,teacher_tokens_sha256=None,chunk_size=32,baseline_jsonl=None,baseline_sha256=None)
            values=[]
            for label,prepare in [('old',old['inputs'].prepare),('proposed',inputs.prepare)]:
                output=folder/label;output.mkdir();fake=Mock();values.append(prepare(args,output,EPOCH,fake))
                fake.verify_model.assert_called_once_with(model.resolve(),ctx['artifact'])
            assert canonical(values[0])==canonical(values[1]);assert 'stage_cut' not in values[1]
            checks.append('omitted-cut retained context bytes')
        print(json.dumps(dict(kind='short_rank_cut_default_python_compatibility',passed=True,checks=checks,
            checks_count=len(checks),context_has_new_default_fields=False,source_fixture_only=True,
            native_model_candidate_or_network_access=False),sort_keys=True,indent=2))
    finally:
        for guard in reversed(guards):guard.stop()


if __name__=='__main__':main()
