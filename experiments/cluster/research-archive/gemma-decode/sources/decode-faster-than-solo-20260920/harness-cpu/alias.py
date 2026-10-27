"""Existing temporary alias lease protocol, retained until native retirement window."""
import json
import os
from pathlib import Path
import select
import shlex
import subprocess
import time
from binding_common import require
from parent_settings import SSH
from lease_source import LEASE


class Alias:
    def __init__(self,output): self.output,self.process,self.password=output,None,''
    def start(self):
        credentials=Path('/Users/developer/DarkbloomDev/machines/CREDENTIALS.private.md')
        rows=[[x.strip().strip('`') for x in line.strip().strip('|').split('|')]
            for line in credentials.read_text().splitlines() if line.startswith('|')]
        self.password=rows[2][[x.lower() for x in rows[0]].index('password')]
        connection=subprocess.run(SSH+['darkbloom-48','/usr/bin/printenv','SSH_CONNECTION'],capture_output=True,text=True,timeout=10,check=True)
        parts=connection.stdout.split();require(len(parts)==4 and ':' not in parts[0] and len(connection.stdout)<4096,'Management connection')
        self.err=(self.output/'alias.stderr').open('xb')
        self.process=subprocess.Popen(SSH+['darkbloom-48',shlex.join(['/usr/bin/sudo','-k','-S','-p','',
            '/usr/bin/python3','-c',LEASE,parts[0]])],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.err,bufsize=0)
        self.process.stdin.write((self.password+'\n').encode());self.process.stdin.flush()
        line=bytearray();until=time.monotonic()+15
        while b'\n' not in line:
            require(time.monotonic()<until,'Alias readiness deadline')
            if not select.select([self.process.stdout],[],[],.25)[0]:continue
            block=os.read(self.process.stdout.fileno(),1);require(block and len(line)<65536,'Alias readiness bound');line.extend(block)
        value=json.loads(line);require(value.get('state')=='ready','Alias refused');return value
    def release(self):
        if self.process is None:return dict(notStarted=True,restored=True)
        try:
            try:self.process.stdin.write(b'release\n');self.process.stdin.flush()
            except (BrokenPipeError,OSError):pass
            # communicate drains the bounded remote result and owns only this SSH child.
            self.process.stdin.close();self.process.stdin=None
            out,_=self.process.communicate(timeout=20)
            require(len(out)<=131072,'Alias final output bound')
            (self.output/'alias.stdout').write_bytes(out)
            values=[json.loads(x) for x in out.splitlines() if x.strip()]
            return dict(exitCode=self.process.returncode,records=values,
                        restored=self.process.returncode==0 and len(values)==1 and values[0].get('restored') is True)
        except BaseException:
            if self.process.returncode is None:self.process.kill();self.process.wait(timeout=5)
            raise
        finally:self.err.close();self.password=''
