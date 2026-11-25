"""Two bounded JSONL records per rank, with namespace-specific validation."""
from pathlib import Path
from .common import parse,require


class Records:
    def __init__(self,directory,rank,epoch,context,namespace):
        self.directory=Path(directory);self.rank=rank;self.epoch=epoch
        self.context=context;self.namespace=namespace;self.offset=0;self.pending=b'';self.rows=[]
    @property
    def terminal(self):return self.rows[1] if len(self.rows)==2 else None
    def poll(self,final=False):
        stderr=self.directory/'stderr.log'
        require(not stderr.exists() or stderr.stat().st_size<=4*1024**2,'Rank stderr exceeds4MiB')
        path=self.directory/'stdout.jsonl';size=path.stat().st_size if path.exists() else 0
        require(self.offset<=size<=self.namespace.MAX_STDOUT,'Rank stdout shrank/exceeds namespace bound')
        if size>self.offset:
            with path.open('rb') as stream:
                stream.seek(self.offset);data=stream.read(self.namespace.MAX_STDOUT-self.offset+1)
            self.offset+=len(data);require(self.offset<=self.namespace.MAX_STDOUT,'Rank stdout grew beyond bound');self.pending+=data
        while b'\n'in self.pending:
            line,self.pending=self.pending.split(b'\n',1)
            require(line and len(line)<=self.namespace.MAX_LINE and len(self.rows)<2,'Invalid line count/size')
            row=parse(line.decode('utf8'));expected=self.namespace.READY if not self.rows else self.namespace.TERMINAL
            require(row.get('kind')==expected,'Wrong ready/terminal order')
            self.namespace.validate(row,self.rank,self.epoch,self.context);self.rows.append(row)
        require(len(self.pending)<=self.namespace.MAX_LINE,'Partial line exceeds namespace bound')
        if final:require(not self.pending and self.terminal is not None,'EOF without completed report')
