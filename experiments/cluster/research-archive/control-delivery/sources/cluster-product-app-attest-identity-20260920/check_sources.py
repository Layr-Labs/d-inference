"""Small source checks only. Never compiles or runs a language fixture."""
import base64, difflib, hashlib, json, re, struct, subprocess
from pathlib import Path
ROOT = Path(__file__).resolve().parent
def digest(b): return hashlib.sha256(b).hexdigest()
def read(name): return json.loads((ROOT/name).read_bytes())
def main():
    for row in read('manifest.json')['members']:
        p=ROOT/row['path']; b=p.read_bytes()
        assert not p.is_symlink() and len(b)==row['bytes'] and digest(b)==row['sha256'],row['path']
    context=read('upstream-context.json')
    for row in context['pins']:
        b=subprocess.check_output(['git','cat-file','blob',row['gitBlob']],cwd=context['repository'])
        assert len(b)==row['bytes'] and digest(b)==row['sha256'],row['path']
    patch=[]; methods=[]; rows=read('overlay.json')
    for row in rows:
        p=ROOT/'proposed'/row['path']; original=ROOT/'original'/row['path']
        before=original.read_bytes() if row['beforeSHA256'] else b''
        assert digest(p.read_bytes())==row['sha256']
        if row['beforeSHA256']:
            assert digest(before)==row['beforeSHA256']
            actual=subprocess.check_output(['git','show',row['baseCommit']+':'+row['path']],cwd=context['repository'])
            assert actual==before
        patch.extend(difflib.unified_diff(before.decode().splitlines(True),p.read_text().splitlines(True),fromfile='a/'+row['path'] if row['beforeSHA256'] else '/dev/null',tofile='b/'+row['path']))
        if row['path'].endswith('_test.go'): methods += [dict(path=row['path'],method=x,language='Go') for x in re.findall(r'func (Test\w+)\(',p.read_text())]
        if row['path'].endswith('Tests.swift'): methods += [dict(path=row['path'],method=x,language='Swift') for x in re.findall(r'@Test func (\w+)\(',p.read_text())]
    assert len(rows)==15 and sum(x['beforeSHA256'] is not None for x in rows)==5
    assert ''.join(patch)==(ROOT/'runtime-and-tests.patch').read_text()
    assert methods==read('staged-tests.json')['methods'] and len(methods)==17
    for row in read('unchanged-controls.json'):
        p=Path(row['path']);assert digest(p.read_bytes())==row['sha256'] and p.stat().st_size==row['bytes']
    key=bytes.fromhex('04'+'6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296'+'4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5')
    text=lambda s:struct.pack('>I',len(s.encode()))+s.encode()
    vectors=read('canonical-vectors.json')
    for tag,name,fields in [(1,'legacy',['serial']),(2,'appAttest',['account','machine','credential','proof'])]:
        raw=b'DBNID\x01'+bytes([tag])+b''.join(text(s) for s in ['member',base64.b64encode(key).decode(),base64.b64encode(bytes([1])*32).decode()])+bytes([2])*32+bytes([3])*32+struct.pack('>Q',7)+b''.join(text(s) for s in fields)
        assert vectors[name]==dict(hex=raw.hex(),bytes=len(raw))
        for rel in ['coordinator/protocol/native_member_identity_test.go','provider-swift/Tests/ProviderCoreTests/NativeMemberIdentityTests.swift']:
            assert raw.hex() in (ROOT/'proposed'/rel).read_text()
    assert base64.b64encode(key).decode() in (ROOT/'proposed/coordinator/registry/app_attest_native_identity_test.go').read_text()
    print(json.dumps(dict(passed=True,manifestSHA256=digest((ROOT/'manifest.json').read_bytes()),overlays=15,upstreamPins=len(context['pins']),unchangedControls=9,stagedMethods=17,languageCodeOrFixturesExecuted=False),sort_keys=True))
if __name__=='__main__':main()
