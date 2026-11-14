#!/usr/bin/env python3
"""Run signed macOS service integration checks with synthetic data under /tmp.
Build pv-background, pv-browser-host and --example service_probe with
--no-default-features --features background-service --release first.
No installed app, browser registration or real vault is used.
"""
from pathlib import Path
import subprocess, tempfile, json, os, time, socket, struct, concurrent.futures, shutil, plistlib
def main():
    ROOT=Path.cwd();work=Path(tempfile.mkdtemp(prefix='pvs-',dir='/tmp'));app=work/'PasswordVault.app';bin=app/'Contents/MacOS';res=app/'Contents/Resources';bin.mkdir(parents=True);res.mkdir()
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.securepass.vault.background.qa','CFBundleExecutable':'PasswordVault','CFBundleName':'PasswordVault Service QA','PVVaultDirectoryName':'Q'}))
    for src,name in [('pv-browser-host','pv-browser-host'),('examples/service_probe','PasswordVault')]:
     shutil.copy2(ROOT/'apps/desktop/target/release'/src,bin/name)
     subprocess.run(['codesign','--force','--sign','-',str(bin/name)],check=True,capture_output=True)
    service_app=app/'Contents/Library/PasswordVault Background.app';service_bin=service_app/'Contents/MacOS/pv-background';service_bin.parent.mkdir(parents=True)
    service_source=Path(__import__('sys').argv[__import__('sys').argv.index('--service-binary')+1]) if '--service-binary' in __import__('sys').argv else ROOT/'apps/desktop/target/release/pv-background'
    shutil.copy2(service_source,service_bin)
    (service_app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.securepass.vault.background.qa.service','CFBundleExecutable':'pv-background','CFBundleName':'PasswordVault QA Background','LSBackgroundOnly':True,'LSUIElement':True}))
    subprocess.run(['codesign','--force','--sign','-',str(service_app)],check=True,capture_output=True)
    shutil.copy2(ROOT/'apps/macos-legacy/Resources/BrowserIdentity.json',res/'BrowserIdentity.json')
    subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
    directory=work/'h/Library/Application Support/Q/vault';env={**os.environ,'HOME':str(work/'h'),'PV_DISABLE_HOTKEY':'1','MallocDeferredReclaim':'0','MallocLargeCache':'0','PV_SERVICE_DIAGNOSTICS':'1'}
    log=(work/'server.log').open('wb')
    launchd='--launchd' in __import__('sys').argv
    agent=f'com.securepass.vault.background.qa.{work.name}'
    domain=f'gui/{os.getuid()}'
    def start_server():
     if not launchd:
      return subprocess.Popen([str(service_bin),'--vault-directory',str(directory)],env=env,stdout=log,stderr=log)
     plist=work/'agent.plist'
     plist.write_bytes(plistlib.dumps({'Label':agent,'ProgramArguments':[str(service_bin),'--vault-directory',str(directory)],'EnvironmentVariables':{k:env[k] for k in ['HOME','PV_DISABLE_HOTKEY','MallocDeferredReclaim','MallocLargeCache']},'ProcessType':'Background','StandardErrorPath':str(work/'server.log')}))
     subprocess.run(['launchctl','bootstrap',domain,str(plist)],capture_output=True)
     subprocess.run(['launchctl','kickstart',f'{domain}/{agent}'],check=True,capture_output=True)
     # The adapter supplies the same lifecycle probes as Popen, without broad kills.
     class Agent:
      pid=None
      def poll(self):
       r=subprocess.run(['launchctl','print',f'{domain}/{agent}'],capture_output=True,text=True)
       import re
       match=re.search(r'\bpid = (\d+)',r.stdout)
       if match:self.pid=int(match.group(1));return None
       return 0
      def kill(self):os.kill(self.pid,9)
      def terminate(self):
       if self.poll() is None:os.kill(self.pid,15)
      def wait(self,timeout=5):
       for _ in range(int(timeout*10)):
        if self.poll() is not None:return
        time.sleep(.1)
       raise RuntimeError('Agent did not stop')
     return Agent()
    server=start_server()
    def call(method,args=None):
     p=subprocess.run([str(bin/'PasswordVault'),str(directory)],input=json.dumps({'method':method,'args':args or {}}),text=True,capture_output=True,timeout=125)
     assert p.returncode==0,p.stderr
     return json.loads(p.stdout)
    def command(value):
     result=call('command',{'request':json.dumps(value)})
     assert 'error' not in result,result
     return json.loads(result['value'])
    try:
     for _ in range(100):
      if (directory/'service.sock').exists():break
      assert server.poll() is None,(work/'server.log').read_text()
      time.sleep(.1)
     reply=call('ping');assert reply.get('value') is True,reply
     assert command({'op':'status'})['unlocked'] is False
     command({'op':'create','password':'fixture'})
     command({'op':'save','item':{'id':'one','type':'password','title':'Fixture','url':'https://fixture.test','username':'fixture','password':'test-value'}})
     assert command({'op':'matches','origin':'https://fixture.test'})[0]['id']=='one'
     assert command({'op':'fill','origin':'https://fixture.test','id':'one'})['password']=='test-value'
     with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
      results=list(pool.map(lambda _:command({'op':'matches','origin':'https://fixture.test'}),range(12)))
     assert all(v[0]['id']=='one' for v in results)
     assert command({'op':'status'})['unlocked'] is True
     # An unsigned/differently signed process cannot submit even status.
     with socket.socket(socket.AF_UNIX) as sock:
      sock.connect(str(directory/'service.sock'));sock.settimeout(2)
      payload=json.dumps({'version':1,'id':'bad','method':'ping','args':{}}).encode()
      try:sock.sendall(struct.pack('<I',len(payload))+payload);denied=not sock.recv(4096)
      except (ConnectionResetError,BrokenPipeError):denied=True
      assert denied
     # Native Messaging uses its actual helper and a synthetic HOME/storage namespace.
     extension=json.loads((res/'BrowserIdentity.json').read_text())['extensionId']
     command({'op':'settings','settings':{'browserPairings':{extension:['fixture-token']}}})
     def browser(request):
      payload=json.dumps({'version':2,'token':'fixture-token',**request}).encode()
      p=subprocess.run([str(bin/'pv-browser-host'),f'chrome-extension://{extension}/'],input=struct.pack('<I',len(payload))+payload,capture_output=True,env=env,timeout=15)
      assert len(p.stdout)>=4,p.stderr
      size=struct.unpack('<I',p.stdout[:4])[0]
      return json.loads(p.stdout[4:4+size])
     assert browser({'op':'matches','origin':'https://fixture.test'})['data'][0]['id']=='one'
     assert browser({'op':'fill','origin':'https://fixture.test','id':'one'})['data']['password']=='test-value'
     metrics=[]
     def footprint(stage):
      text=subprocess.run(['footprint','-p',str(server.pid)],capture_output=True,text=True,check=True).stdout
      import re
      value=re.search(r'phys_footprint:\s+([^\n]+)',text).group(1).strip()
      metrics.append({'stage':stage,'physicalFootprint':value})
     if '--memory' in __import__('sys').argv or '--latency' in __import__('sys').argv:
      footprint('small unlocked background')
      records=[{'id':f'account-{i}','type':'password','title':f'Fixture {i}','url':f'https://site-{i}.test','username':'fixture','password':'test-value','updatedAt':'2026-01-01T00:00:00Z'} for i in range(1000)]
      command({'op':'import','content':json.dumps({'items':records})})
      time.sleep(1);footprint('1000 accounts background')
      command({'op':'import','content':json.dumps({'items':[{'id':'large-note','type':'secureNote','title':'Fixture note','note':'n'*8_000_000,'updatedAt':'2026-01-01T00:00:00Z'}]})})
      time.sleep(1);footprint('1000 accounts plus 8 MB note background')
      for _ in range(50):command({'op':'matches','origin':'https://site-500.test'})
      footprint('after 50 browser queries')
      if '--hold' in __import__('sys').argv:
       print(json.dumps({'pid':server.pid}),flush=True);time.sleep(45)
     latency={}
     if '--latency' in __import__('sys').argv:
      command({'op':'save','item':{'id':'selected-note','type':'secureNote','title':'Small fixture','note':'small body'}})
      # A persistent, signed frontend keeps the same PID across requests. It is
      # distinct from the one-shot browser helper and exits before idle sampling.
      client=subprocess.Popen([str(bin/'PasswordVault'),str(directory),'--stream'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
      try:
       timings=[]
       for _ in range(13):
        start=time.perf_counter()
        client.stdin.write(json.dumps({'method':'command','args':{'request':json.dumps({'op':'get','id':'selected-note'})}})+'\n');client.stdin.flush()
        reply=json.loads(client.stdout.readline());assert 'error' not in reply,reply
        assert json.loads(reply['value'])['note']=='small body'
        timings.append((time.perf_counter()-start)*1000)
       import statistics
       latency={'coldMs':round(timings[0],2),'warmMedianMs':round(statistics.median(timings[1:]),2),'warmMaxMs':round(max(timings[1:]),2)}
      finally:
       client.stdin.close();client.wait(timeout=5)
      time.sleep(1);footprint('after frontend exits')
     command({'op':'lock'})
     assert call('command',{'request':json.dumps({'op':'fill','origin':'https://fixture.test','id':'one'})})['error']=='Locked'
     command({'op':'unlock','password':'fixture'})
     server.kill();server.wait();server=start_server()
     time.sleep(1)
     assert command({'op':'status'})['unlocked'] is False
     assert call('shutdown')['value'] is None
     server.wait(timeout=5)
     print(json.dumps({'passed':True,'scenarios':['signed IPC','CRUD','concurrent queries','wrong identity rejection','native messaging helper','lock','crash restart locked','shutdown','polling cannot restart after quit'],'work':str(work),'memory':metrics,'latency':latency}))
    except BaseException:
     print((work/'server.log').read_text());raise
    finally:
     if server.poll() is None:server.terminate();server.wait(timeout=5)
     if launchd:subprocess.run(['launchctl','bootout',f'{domain}/{agent}'],capture_output=True)

if __name__ == "__main__":
    main()
