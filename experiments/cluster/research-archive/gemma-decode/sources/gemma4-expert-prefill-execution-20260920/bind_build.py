"""Create the actual build binding from explicitly pinned successful receipts."""
import argparse
import json
from build_binding import ROOT, compose

def main():
    parser=argparse.ArgumentParser(allow_abbrev=False)
    for name in ('axis','rdma','sources'):
        parser.add_argument('--'+name+'-receipt',required=True)
        parser.add_argument('--'+name+'-sha256',required=True)
    args=parser.parse_args()
    refs=[dict(path=getattr(args,name+'_receipt'),sha256=getattr(args,name+'_sha256'))
          for name in ('axis','rdma','sources')]
    binding=compose(*refs)
    with (ROOT/'artifact-bindings.json').open('x') as stream:
        json.dump(binding,stream,indent=2);stream.write('\n')
    print(json.dumps(dict(bound=True,products=binding['products'],sources=binding['appliedSources'])))

if __name__=='__main__':main()
