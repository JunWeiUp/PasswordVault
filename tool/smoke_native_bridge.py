"""Interactive signed-helper smoke test. Requires an unlocked seed_demo fixture, never a real vault."""
import argparse
import json
import os
import pathlib
import socket
import struct
import subprocess
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--fixture-dir',required=True)
parser.add_argument('--app',default='apps/macos/build/Build/Products/Debug/PasswordVault.app')
args=parser.parse_args()
folder=str(pathlib.Path(args.fixture_dir).resolve())
assert pathlib.Path(folder,'.synthetic-fixture').read_text()=='PasswordVault synthetic fixture v2\n', 'Refusing a non-fixture vault'
application=pathlib.Path(args.app).resolve()
env=os.environ.copy();env['PASSWORDVAULT_TEST_SOCKET']=folder+'/bridge.sock'
identity=json.loads((application/'Contents/Resources/BrowserIdentity.json').read_text())['extensionId']
helper=str(application/'Contents/MacOS/PasswordVaultBridge')
proc=subprocess.Popen([helper,'chrome-extension://'+identity+'/'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=env)
def request(body):
 data=json.dumps({'version':2,**body}).encode();proc.stdin.write(struct.pack('<I',len(data))+data);proc.stdin.flush();prefix=proc.stdout.read(4);assert len(prefix)==4,'No response';return json.loads(proc.stdout.read(struct.unpack('<I',prefix)[0]))
assert request({'op':'status'})['unlocked']
print('Waiting for the app pairing confirmation for the synthetic fixture',flush=True)
paired=request({'op':'pair'});assert paired['ok'];token=paired['token']
assert request({'op':'matches','origin':'https://mail.example.com','token':'invalid'})['error']=='unpaired'
matched=request({'op':'matches','origin':'https://mail.example.com','token':token});assert matched['ok'] and len(matched['data'])>=1
item=matched['data'][0]
filled=request({'op':'fill','id':item['id'],'origin':'https://mail.example.com','token':token});assert filled['ok'] and filled['data']['password'].startswith('Synthetic-only-')
assert not request({'op':'fill','id':item['id'],'origin':'https://attacker.example','token':token})['ok']
assert request({'op':'export','password':'not-exposed','token':token})['error']=='unsupported'
assert request({'op':'lock','token':token})['ok']
assert request({'op':'fill','id':item['id'],'origin':'https://mail.example.com','token':token})['error']=='locked'
proc.stdin.close();proc.wait(timeout=5)
sock=socket.socket(socket.AF_UNIX);sock.settimeout(5);sock.connect(folder+'/bridge.sock')
try:
 sock.sendall(b'\x02\x00\x00\x00{}');assert sock.recv(4)==b''
except ConnectionResetError:pass
finally:sock.close()
print('PASS: signed helper pairing, scoped match/fill, bad token/origin, restricted operations, lock denial, and rejection of unsigned socket client',flush=True)
