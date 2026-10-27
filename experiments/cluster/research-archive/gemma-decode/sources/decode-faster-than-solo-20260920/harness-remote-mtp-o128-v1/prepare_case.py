import argparse
from jobs import prepare
p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--case',required=True);p.add_argument('--output-count',type=int,choices=[16,128],default=16);p.add_argument('--prompt',type=int,choices=[128,4096],required=True)
p.add_argument('--depth',type=int,choices=[1,2],default=2);p.add_argument('--capture',action='store_true');p.add_argument('--embedding-sha256',required=True);a=p.parse_args()
assert a.case and all(c.isalnum() or c in '-_' for c in a.case)
prepare(a.case,a.prompt,a.capture,a.embedding_sha256,a.depth,a.output_count)
