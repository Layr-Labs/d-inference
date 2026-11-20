"""Create a hostname-constrained private development CA and coordinator certificate."""
import hashlib
import json
import os
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent
HELPERS = BASE.parent / 'cluster-member-install-actor-correction-20260917'
sys.path.insert(0, str(HELPERS))
from check_process import run_owned

HOST = 'm4-max-36gb-connected.tail618116.ts.net'
OUT = BASE / 'development-ca-1'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    OUT.mkdir(mode=0o700)
    receipt = dict(status='failed', hostname=HOST, trustInstalled=False, productionChanged=False, steps=[])
    ca = '''[req]
distinguished_name=dn
x509_extensions=ca_ext
prompt=no
[dn]
CN=Darkbloom private cluster development CA 20260917
[ca_ext]
basicConstraints=critical,CA:true,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
nameConstraints=critical,permitted;DNS:''' + HOST + '\n'
    leaf = '''[req]
distinguished_name=dn
prompt=no
[dn]
CN=''' + HOST + '''
[leaf_ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:''' + HOST + '''
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
'''
    for name, value in [('ca.cnf', ca), ('server.cnf', leaf)]:
        with (OUT / name).open('x') as stream:
            stream.write(value)
    commands = [
        ('ca-key', ['ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', str(OUT / 'ca.key')]),
        ('ca-certificate', ['req', '-x509', '-new', '-key', str(OUT / 'ca.key'), '-sha256', '-days', '14', '-config', str(OUT / 'ca.cnf'), '-out', str(OUT / 'ca.crt')]),
        ('server-key', ['ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', str(OUT / 'server.key')]),
        ('server-csr', ['req', '-new', '-key', str(OUT / 'server.key'), '-config', str(OUT / 'server.cnf'), '-out', str(OUT / 'server.csr')]),
        ('server-certificate', ['x509', '-req', '-in', str(OUT / 'server.csr'), '-CA', str(OUT / 'ca.crt'), '-CAkey', str(OUT / 'ca.key'), '-CAcreateserial', '-days', '7', '-sha256', '-extfile', str(OUT / 'server.cnf'), '-extensions', 'leaf_ext', '-out', str(OUT / 'server.crt')]),
        ('chain', ['verify', '-purpose', 'sslserver', '-CAfile', str(OUT / 'ca.crt'), str(OUT / 'server.crt')]),
    ]
    try:
        for name, arguments in commands:
            receipt['steps'].append(run_owned(['/usr/bin/openssl'] + arguments, OUT, name, 15))
        for name in ('ca.key', 'server.key'):
            if (OUT / name).stat().st_mode & 0o077:
                raise ValueError('Private key permissions are too broad')
        receipt.update(status='passed', certificateSHA256={name: sha(OUT / name) for name in ('ca.crt', 'server.crt')},
                       caValidDays=14, serverValidDays=7, privateKeyPermissions='0600',
                       pathLength=0, hostnameConstrainedCA=True, serverAuthenticationOnly=True)
    finally:
        with (OUT / 'receipt.json').open('x') as stream:
            json.dump(receipt, stream, indent=2, sort_keys=True)
            stream.write('\n')
    print(json.dumps({key: value for key, value in receipt.items() if key != 'steps'}, sort_keys=True))

if __name__ == '__main__':
    os.umask(0o077)
    main()
