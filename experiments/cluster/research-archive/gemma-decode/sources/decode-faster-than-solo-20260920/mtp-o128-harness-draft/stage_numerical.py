from pathlib import Path
import json,ast
D=Path(__file__).resolve().parent;B=D.parent;R=B.parent
S=B/'harness-local-mtp-packed-head-v1';N=R/'gemma4-mtp-remote-packed-head-numerical-empty-20260920'
rows=[]
s=(S/'numerical_compare.py').read_text();before=s

def change(a,b,count=1):
 global s
 assert s.count(a)==count,(a,s.count(a));s=s.replace(a,b);rows.append(dict(before=a,after=b,count=count))
change('from snapshot import snapshot','from snapshot import snapshot\nfrom workload_contract import counts, state_geometry')
workload_sha=__import__('hashlib').sha256((D/'proposed/local/workload_contract.py').read_bytes()).hexdigest()
change("'snapshot.py': '46dfa5689fba4358412c6c4ce03a759ca71d5c30bcde9df995a46c4aad97873b'}","'snapshot.py': '46dfa5689fba4358412c6c4ce03a759ca71d5c30bcde9df995a46c4aad97873b',\n           'workload_contract.py': '"+workload_sha+"'}")
old="""    require(job['schema']=='gemma4_resident_benchmark_v1' and job['mode']=='full'
            and job['promptCount']==128 and job['chunkSize']==64 and job['outputCount']==16 and job['cut']==7
            and job['residualDType']=='bfloat16' and job['prefillPolicy']=='serial' and job['timeoutSeconds']==300,
            'Comparator requires exact P128/C64/O16/cut7 ordinary arithmetic')"""
change(old,"    counts(job)")
change("'prompt='+tokens,'chunk=64','output=16','stop='","'prompt='+tokens,'chunk=64','output='+str(counts(job)['output']),'stop='")
change('def binding(value, load):','def binding(value, load, job):\n    c=counts(job)')
change("value['maximumTokens']==144","value['maximumTokens']==c['maximumTokens']")
change("'maximumTokens=144'","'maximumTokens='+str(c['maximumTokens'])")
change('def state(value, bind, sidecars, ordinal):','def state(value, bind, sidecars, ordinal, frontier):')
change("value['frontier']==143","value['frontier']==frontier")
old="""        dtype='int32' if position else geometry['dtype']
        shape=[1] if position else [1,geometry['kvHeads'],143,geometry['headDimension']]
        count=math.prod(shape)*WIDTH[dtype]; logical=[] if position else [0,143]"""
change(old,"        dtype,shape,count,logical=state_geometry(geometry,component,frontier)")
change("struct.pack('<i',143)","struct.pack('<i',frontier)")
change("identity+='|range=0:143'","identity+=f'|range={logical[0]}:{logical[1]}'")
change("'tokens=143'","'tokens='+str(frontier)")
change("    equal(workload(ja),workload(jb),'Semantic prompt/model/build/math differs')","    equal(workload(ja),workload(jb),'Semantic prompt/model/build/math differs')\n    c=counts(ja)")
change('and len(prompt)==128',"and len(prompt)==c['prompt']")
change("generation['committedTokens']==143","generation['committedTokens']==c['frontier']")
change('len(tokens)==16',"len(tokens)==c['output']")
change("binding(sample['binding'],(ordinary,mtp)[index]['sourceLoad'])","binding(sample['binding'],(ordinary,mtp)[index]['sourceLoad'],job)")
change("state(e['finalState'],s['binding'],sc,ordinal)","state(e['finalState'],s['binding'],sc,ordinal,c['frontier'])")
change('sum(accepted)+len(widths)==15',"sum(accepted)+len(widths)==c['decode']")
change("schema='gemma4_p128_local_mtp_numerical_comparison_v1'","schema='gemma4_output_bound_local_mtp_numerical_comparison_v1'")
change('promptTokens=128,chunkTokens=64,outputTokens=16',"promptTokens=c['prompt'],chunkTokens=64,outputTokens=c['output']")
change('generatedTokensCompared=64',"generatedTokensCompared=c['allGeneratedTokens']")
change("scope='same-build P128 final full rows, full90 states and all16 generated IDs for four actual requests'","scope='same-build complete final rows/full90 chronological states and all bound generated IDs for four actual requests'")
change('"""Read-only P128 same-build ordinary versus local-MTP numerical replay."""','"""Read-only closed P128/P4096 O16/O128 same-build full evidence replay."""')
p=D/'proposed/local/numerical_compare.py';p.parent.mkdir(parents=True,exist_ok=True);p.write_text(s);ast.parse(s)
# Remote uses this exact generalized reader; orchestration is separately bound.
p=D/'proposed/numerical/numeric_reader.py';p.write_text(s)
reader_ops=rows;rows=[];s=(N/'compare.py').read_text();before_remote=s
change('import numeric_reader as n','import numeric_reader as n\nfrom control_contract import validate_control_metrics')
change("    n.require(terminal['nativeOperation']", "    validate_control_metrics(remote)\n    n.require(terminal['nativeOperation']")
change("    load=remote['sourceLoad'];plan=load['planSHA256']", "    depth=config['maximumDraftTokens']\n    n.require(type(depth) is int and depth in (1,2),'Exact chosen remote verification depth')\n    load=remote['sourceLoad'];plan=load['planSHA256']")
change("'depth=2','buffer=5'", "'depth='+str(depth),'buffer=5'")
change('1<=w<=3 for w in widths','1<=w<=depth+1 for w in widths')
change("requests[0],'129','143'","requests[0],str(n.counts(job)['prompt']+1),str(n.counts(job)['frontier'])")
change("    n.equal(semantic(ja),semantic(jb),'Semantic workload/model/build differs')","    n.equal(semantic(ja),semantic(jb),'Semantic workload/model/build differs')\n    c=n.counts(ja)")
change('and len(prompt)==128',"and len(prompt)==c['prompt']")
change("sample['committedTokens']==143","sample['committedTokens']==c['frontier']")
change('len(tokens)==16',"len(tokens)==c['output']")
change("n.binding(sample['binding'],report['sourceLoad'])","n.binding(sample['binding'],report['sourceLoad'],job)")
change("n.state(ev['finalState'],sample['binding'],sc,ordinal)","n.state(ev['finalState'],sample['binding'],sc,ordinal,c['frontier'])")
change('len(widths)+sum(accepted)==15',"len(widths)+sum(accepted)==c['decode']")
change("schema='gemma4_p128_remote_packed_head_mtp_numerical_comparison_v1'","schema='gemma4_output_bound_remote_packed_head_mtp_numerical_comparison_v1'")
change('requestsCompared=4,generatedTokensCompared=64',"requestsCompared=4,promptTokens=c['prompt'],outputTokens=c['output'],generatedTokensCompared=c['allGeneratedTokens']")
change('sameBuildP128RemoteNumericsQualified=True','sameBuildFinalRemoteNumericsQualified=True')
change('"""Root-only exact same-build P128 ordinary versus real remote MTP replay."""','"""Root-only exact closed-output same-build ordinary versus remote MTP replay."""')
p=D/'proposed/numerical/compare.py';p.write_text(s);ast.parse(s)
(D/'numerical-operations.json').write_text(json.dumps(dict(readerBase=str(S/'numerical_compare.py'),readerOperations=reader_ops,remoteBase=str(N/'compare.py'),remoteOperations=rows),indent=2)+'\n')
print('numerical source staged; raw math/physical/readers unchanged except explicit workload/binding/state geometry adaptation')
