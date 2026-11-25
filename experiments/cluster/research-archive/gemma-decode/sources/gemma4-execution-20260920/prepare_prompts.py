"""Tokenize authored text with the exact registered tokenizer; never loads MLX."""
import hashlib
import importlib.metadata
import json
from pathlib import Path
from tokenizers import Tokenizer

ROOT=Path(__file__).resolve().parent
MODEL=Path('/Users/developer/.cache/huggingface/hub/models--gemma-4-26b-qat-4bit/snapshots/local')
MANIFEST=Path('/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Tests/StageMetadataChecks/Inputs/manifest.json')
ARTIFACT='2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785'
TOPICS=[
    'A gardener checks moisture below the surface before watering young trees. '
    'Roots require both water and air. Soil texture, recent rain, temperature and '
    'wind change the watering schedule. Explain observations before choosing an action.',
    'A distributed computing system divides a large task among several computers. '
    'Its throughput depends on arithmetic work, memory capacity, data transfer and '
    'synchronization. A useful experiment changes one condition while keeping the '
    'input and measurement method constant. Record uncertainty and unsuccessful runs.',
    'A library keeps a catalog of books, authors and subjects. A search program '
    'should normalize queries, preserve original titles, and distinguish missing '
    'records from temporary errors. Describe a small example and the expected result.',
    'An engineer compares two bridge designs using identical loading conditions. '
    'Material strength is only one consideration: weight, stiffness, fatigue and '
    'maintenance also matter. State assumptions and explain which evidence could '
    'change the recommendation.',
]

def main():
    manifest=json.loads(MANIFEST.read_bytes())
    assert manifest['aggregate_sha256']==ARTIFACT
    row=next(row for row in manifest['files'] if row['path']=='tokenizer.json')
    raw=(MODEL/'tokenizer.json').read_bytes()
    assert len(raw)==row['size_bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256']
    tokenizer=Tokenizer.from_str(raw.decode())
    text='Read the following notes and continue with a clear, reasoned explanation.\n\n'
    for index in range(256):
        text+=f'Note {index+1}: '+TOPICS[index%len(TOPICS)]+'\n\n'
    ids=tokenizer.encode(text,add_special_tokens=True).ids
    assert len(ids)>=8192 and all(0<=x<262144 for x in ids)
    out=ROOT/'prompts';out.mkdir(mode=0o700)
    (out/'source.txt').write_text(text)
    receipt=dict(artifactSHA256=ARTIFACT,tokenizerSHA256=row['sha256'],
                 tokenizerVersion=importlib.metadata.version('tokenizers'),
                 textSHA256=hashlib.sha256(text.encode()).hexdigest(),
                 chatTemplateApplied=False,selection='first N tokens of authored text',files=[])
    for count in [128,256,1024,4096,8192]:
        data=(json.dumps(ids[:count],separators=(',',':'))+'\n').encode()
        path=out/f'prompt-{count}.json';path.write_bytes(data);path.chmod(0o600)
        receipt['files'].append(dict(path=path.name,promptCount=count,sha256=hashlib.sha256(data).hexdigest()))
    (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt))

if __name__=='__main__':main()
