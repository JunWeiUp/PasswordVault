import assert from 'node:assert/strict';
// Run using ego-browser with a TaskSpace-owned page and this repository served
// on loopback. The fixture is a synthetic runtime, never a real vault.
export async function run(page, base = 'http://127.0.0.1:4388') {
  const results = [];
  async function load(query = '') {
    await page.goto(base + '/tests/fixtures/popup-confirmation.html' + query);
    await page.waitForSelector('#capture-password');
    await page.waitForFunction(() => !!document.querySelector('#popup-style').sheet);
  }
  async function poll() {
    const count = await page.evaluate(() => qa.reads);
    await page.waitForFunction(count => qa.reads > count, count);
  }
  async function visibleActions() {
    const bounds = await page.evaluate(() => {
      const form = document.querySelector('.capture');
      return [...form.querySelectorAll('input,.actions button')].map(e => {
        const r = e.getBoundingClientRect(); return {top:r.top,bottom:r.bottom,left:r.left,right:r.right,height:innerHeight,width:document.documentElement.clientWidth};
      });
    });
    for (const r of bounds) assert.ok(r.top >= 0 && r.bottom <= r.height && r.left >= 0 && r.right <= r.width, JSON.stringify(r));
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth), false);
  }
  await page.cdp('Emulation.setDeviceMetricsOverride', {width:380,height:600,deviceScaleFactor:1,mobile:false});
  await load();
  await visibleActions();
  assert.equal(await page.evaluate(() => document.querySelector('.site-accounts').open), false);
  results.push('380×600: confirmation and both actions visible with 30 matches; no horizontal scroll');
  assert.equal(await page.evaluate(() => document.querySelector('#capture-password').type), 'password');
  await page.click('button[aria-label="显示密码"]');
  assert.equal(await page.evaluate(() => document.querySelector('#capture-password').type), 'text');
  await page.fill('#capture-username', 'edited@example.test');
  await page.fill('#capture-password', 'Fictional-edited-208!');
  await poll();
  assert.equal(await page.evaluate(() => document.querySelector('#capture-password').value === 'Fictional-edited-208!'), true);
  await page.click('.capture .primary');
  await page.waitForSelector('.capture', {state:'detached'});
  assert.equal(await page.evaluate(() => qa.saved.length === 1 && qa.saved[0].username === 'edited@example.test' && qa.saved[0].password === 'Fictional-edited-208!'), true);
  results.push('reveal, edit username/password, polling preservation and exact save payload');
  await load();
  await page.focus('button[aria-label="显示密码"]');
  await page.keyboard.press('Enter');
  assert.equal(await page.evaluate(() => qa.saved.length === 0 && document.querySelector('#capture-password').type === 'text'), true);
  await page.keyboard.press('Tab');
  assert.equal(await page.evaluate(() => document.activeElement.textContent), '取消保存');
  await page.keyboard.press('Enter');
  await page.waitForSelector('.capture', {state:'detached'}); await poll();
  assert.equal(await page.evaluate(() => qa.saved.length === 0 && qa.dismissed.length === 1 && !document.querySelector('.capture')), true);
  results.push('keyboard eye does not submit; Tab/Enter cancels; reminder stays dismissed after polling');
  await load(); await page.click('button[aria-label="显示密码"]');
  await page.evaluate(() => window.dispatchEvent(new Event('blur')));
  await page.waitForFunction(() => document.querySelector('#capture-password').type === 'password');
  await page.click('button[aria-label="显示密码"]');
  await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
  await page.waitForFunction(() => document.querySelector('#capture-password').type === 'password');
  results.push('window blur and visibility changes conceal plaintext');
  await page.click('button[aria-label="显示密码"]');
  await page.evaluate(() => { qa.pending = {...qa.pending, id:'fixture-2', password:'Fictional-next-208!'}; });
  await poll();
  assert.equal(await page.evaluate(() => document.querySelector('#capture-password').type === 'password' && document.querySelector('#capture-password').value === 'Fictional-next-208!'), true);
  await page.evaluate(() => { qa.pending = undefined; }); await poll();
  assert.equal(await page.evaluate(() => !document.querySelector('#capture-password')), true);
  results.push('new pending record conceals; expired pending removes secret from DOM');
  await load('?sourceTabId=123');
  await page.evaluate(() => {
    qa.origin='https://'+'very-long-account-subdomain-'.repeat(4)+'example.test';
    qa.pending={...qa.pending,id:'long-site',origin:qa.origin};
    qa.failSave=true;
  });
  await poll();
  await page.click('button[aria-label="显示密码"]');
  await page.click('.capture .primary');
  await page.waitForSelector('.capture [role="alert"]');
  await visibleActions();
  assert.equal(await page.evaluate(() => document.querySelector('#capture-password').type === 'password' && qa.saved.length === 0), true);
  results.push('source-tab return + long two-line origin + save error: inputs and actions stay visible, values preserved and concealed');
  await page.evaluate(() => { qa.state.unlocked=false; qa.pending=undefined; });
  await page.waitForFunction(() => !document.querySelector('#capture-password'));
  assert.equal(await page.evaluate(() => !document.querySelector('#capture-password')), true);
  results.push('clearing pending on explicit lock removes captured credentials from the UI');
  await load();
  await page.evaluate(() => { qa.state.mode='independent'; }); await poll();
  await page.click('.capture .actions button[type="button"]');
  await page.waitForSelector('.capture', {state:'detached'});
  await page.click('text="保存网页中的账号"');
  await page.waitForSelector('#capture-password');
  await visibleActions();
  assert.equal(await page.evaluate(() => document.querySelector('#capture-password').type === 'password' && document.querySelector('#capture-password').value === 'Fictional-manual-208!'), true);
  results.push('independent mode and manual capture use the same visible, concealed confirmation');
  return results;
}

export async function runEditNavigation(page, base = 'http://127.0.0.1:4388') {
  await page.goto(base + '/tests/fixtures/popup-confirmation.html');
  await page.waitForSelector('#capture-password');
  await page.click('.capture .actions button[type="button"]');
  await page.waitForSelector('.capture', {state:'detached'});
  await page.click('.match-row:first-child .match');
  await page.waitForFunction(() => qa.edited.length === 1);
  assert.equal(await page.evaluate(() => qa.edited[0].id === '0' && qa.filled.length === 0 && !('password' in qa.edited[0])), true);
  await page.click('.match-row:nth-child(2) .match');
  await page.waitForFunction(() => qa.edited.length === 2);
  assert.equal(await page.evaluate(() => qa.edited[1].id === '0' && qa.edited[1].accountId === 'extra'), true);
  await page.evaluate(() => { qa.failEdit = 'unsupported'; });
  await page.click('.match-row:first-child .match');
  await page.waitForSelector('[role=alert]');
  assert.equal(await page.evaluate(() => document.querySelector('[role=alert]').textContent.includes('更新 Mac') && ![...document.querySelectorAll('main [role=status]')].some(el => el.textContent.includes('已在 Mac 中打开该账号'))), true);
  await page.evaluate(() => { qa.failEdit = undefined; window.close = () => {}; });
  await page.click('.match-row:first-child .match-fill');
  await page.waitForFunction(() => qa.filled.length === 1);
  await page.evaluate(() => { qa.state.mode='independent'; });
  await page.waitForFunction(() => !document.querySelector('.match-fill'));
  await page.click('.match-row:first-child .match');
  await page.waitForFunction(() => qa.filled.length === 2);
  assert.equal(await page.evaluate(() => qa.edited.length === 2), true);
  return ['Native primary account navigates without fill or password payload', 'Additional account ID is preserved', 'Older Mac shows update guidance without stale success notice', 'Dedicated Fill remains separate', 'Independent accounts fill without contacting Mac'];
}

export async function runOffline(page, base='http://127.0.0.1:4388') {
  await page.goto(base+'/tests/fixtures/popup-confirmation.html');
  await page.waitForSelector('#capture-password');
  await page.evaluate(()=>{qa.state={mode:'native',available:false,unlocked:false,paired:false,queued:2};});
  await page.waitForFunction(()=>document.body.textContent.includes('暂存 2 个账号'));
  assert.equal(await page.evaluate(()=>!!document.querySelector('#capture-password')),true);
  await page.click('.capture .primary');
  await page.waitForSelector('.capture',{state:'detached'});
  assert.equal(await page.evaluate(()=>qa.saved.length),1);
  await page.click('text="保存网页中的账号"');
  await page.waitForSelector('#capture-password');
  assert.equal(await page.evaluate(()=>document.querySelector('#capture-password').type),'password');
  return ['offline capture remains reviewable','offline save dispatches only on confirmation','manual page capture remains available offline'];
}

export async function runManualAdd(page, base = 'http://127.0.0.1:4388') {
  const results = [];
  for (const mode of ['native', 'independent']) {
    await page.goto(base + '/tests/fixtures/popup-confirmation.html');
    await page.waitForSelector('#capture-password');
    await page.click('.capture .actions button[type="button"]');
    await page.evaluate(mode => { qa.state.mode = mode; qa.state.available = false; }, mode);
    await page.waitForFunction(mode => document.querySelector(`.mode-switch button:nth-child(${mode === 'native' ? 1 : 2})`).getAttribute('aria-pressed') === 'true', mode);
    await page.click('text="添加账号密码"');
    await page.waitForSelector('#capture-password');
    assert.equal(await page.evaluate(() => document.querySelector('#capture-password').value), '');
    await page.click('.capture .primary');
    assert.equal(await page.evaluate(() => qa.saved.length), 0);
    await page.fill('#capture-username', 'manual-add@example.test');
    await page.fill('#capture-password', 'Fictional-add-only!');
    const count = await page.evaluate(() => { qa.failSave = true; return qa.reads; });
    await page.waitForFunction(count => qa.reads > count, count);
    await page.click('.capture .primary');
    await page.waitForSelector('.capture [role="alert"]');
    assert.equal(await page.evaluate(() => document.querySelector('#capture-password').value), 'Fictional-add-only!');
    await page.evaluate(() => { qa.failSave = false; });
    await page.click('.capture .primary');
    await page.waitForSelector('.capture', {state:'detached'});
    assert.equal(await page.evaluate(() => qa.saved.length === 1 && qa.saved[0].origin === qa.origin && qa.saved[0].username === 'manual-add@example.test' && qa.saved[0].password === 'Fictional-add-only!'), true);
    await page.click('text="添加账号密码"');
    await page.fill('#capture-password', 'Fictional-cancel-only!');
    await page.click('.capture .actions button[type="button"]');
    assert.equal(await page.evaluate(() => qa.saved.length === 1 && !document.querySelector('#capture-password')), true);
    await page.click('text="添加账号密码"');
    await page.evaluate(() => { qa.origin = 'https://different.example.test'; });
    await page.waitForSelector('.capture', {state:'detached'});
    results.push(mode + ': blank required fields, polling, retry, bound-origin payload, cancel, navigation cleanup');
  }
  return results;
}

export async function runBackgroundSync(page, base = 'http://127.0.0.1:4389') {
  await page.goto(base + '/tests/fixtures/popup-confirmation.html');
  await page.evaluate(() => { qa.pending=undefined;qa.state={mode:"native",available:true,unlocked:false,paired:false,syncSupported:true,syncReady:false}; });
  await page.waitForSelector('#background-sync-password');
  await page.fill('#background-sync-password', 'wrong-fictional');
  await page.click('text="确认授权"');
  await page.waitForFunction(() => document.body.textContent.includes('密码不正确'));
  assert.equal(await page.evaluate(() => document.querySelector('#background-sync-password').value),'');
  await page.fill('#background-sync-password', 'Fictional-master-2026!');
  await page.click('text="确认授权"');
  await page.waitForFunction(() => document.body.textContent.includes('Mac 账号已连接'));
  assert.equal(await page.evaluate(() => !!document.querySelector('#background-sync-password')),false);
  assert.equal(await page.evaluate(() => document.body.scrollWidth <= innerWidth),true);
  assert.equal(await page.evaluate(() => qa.state.readReady && qa.state.autoUnlockReady),true);
  await page.click('.authorization-settings > summary');
  await page.click('text="关闭 Mac 自动解锁"');
  await page.waitForFunction(() => !qa.state.autoUnlockReady);
  assert.equal(await page.evaluate(() => qa.state.readReady),true);
  await page.click('text="撤销此插件授权"');
  await page.waitForSelector('#background-sync-password');
  return ['Wrong password clears secret and preserves setup', 'Explicit read/startup scopes configured while Mac is closed', 'Startup scope can be disabled without revoking reads', 'Full revocation returns to masked configuration'];
}

export async function runAuthorizedAccounts(page, base = 'http://127.0.0.1:4389') {
  await page.goto(base + '/tests/fixtures/popup-confirmation.html');
  await page.evaluate(() => {
    qa.pending=undefined;
    qa.state={mode:"native",available:true,unlocked:true,paired:true,syncSupported:true,syncReady:true,readReady:true,autoUnlockReady:true,desktopUnlocked:false};
  });
  await page.waitForSelector('.capture',{state:'detached'});
  await page.waitForFunction(()=>document.body.textContent.includes('Mac 账号已连接'));
  const selector='.match-row:first-child .account-secret';
  assert.equal(await page.evaluate(()=>document.querySelector('.site-accounts summary').textContent.includes('30')),true);
  assert.equal(await page.evaluate(()=>document.body.textContent.includes('Fictional-existing-account!')),false);
  await page.click(selector+' button');
  await page.waitForFunction(()=>document.querySelector('.match-row:first-child .account-secret code').textContent==='Fictional-existing-account!');
  assert.equal(await page.evaluate(()=>qa.revealed.length===1),true);
  await page.evaluate(()=>window.dispatchEvent(new Event('blur')));
  await page.waitForFunction(()=>document.querySelector('.match-row:first-child .account-secret code').textContent==='••••••••');
  await page.evaluate(()=>{qa.delayReveal=true;});
  await page.click(selector+' button');
  await page.waitForFunction(()=>!!qa.releaseReveal);
  await page.evaluate(()=>{window.dispatchEvent(new Event('blur'));qa.releaseReveal();qa.delayReveal=false;});
  await page.waitForFunction(()=>!document.querySelector('.match-row:first-child .account-secret button').disabled);
  assert.equal(await page.evaluate(()=>document.body.textContent.includes('Fictional-existing-account!')),false);
  await page.click(selector+' button');
  await page.waitForFunction(()=>document.querySelector('.match-row:first-child .account-secret code').textContent==='Fictional-existing-account!');
  await page.evaluate(()=>{qa.origin='https://other.example.test';});
  await page.waitForFunction(()=>document.querySelector('.match-row:first-child .account-secret code').textContent==='••••••••');
  assert.equal(await page.evaluate(()=>document.body.scrollWidth<=innerWidth),true);
  return ['Current-site count and masked account list available with desktop closed', 'Explicit password reveal only; blur conceals it', 'Late reveal after blur is discarded', 'Origin change clears displayed password and layout fits'];
}

export async function runMacHeader(page, base = 'http://127.0.0.1:4390') {
  await page.goto(base + '/tests/fixtures/popup-confirmation.html');
  await page.waitForSelector('.brand-version');
  const metadata = await page.evaluate(async () => (await fetch('/package.json')).json());
  assert.equal(await page.evaluate(() => document.querySelector('.brand-version').textContent), 'v' + metadata.version);
  await page.click('.mac-launch');
  assert.equal(await page.evaluate(() => qa.opened), 1);
  assert.equal(await page.evaluate(() => !!document.querySelector('.mac-download-notice')), false);
  await page.evaluate(() => { qa.pending=undefined; qa.state={mode:'independent',exists:true,unlocked:false}; qa.openError='native-host-missing'; });
  await page.click('.mac-launch');
  await page.waitForSelector('.mac-download-notice a');
  assert.equal(await page.evaluate(() => document.querySelector('.mac-download-notice a').href), 'https://github.com/JunWeiUp/PasswordVault/releases');
  assert.equal(await page.evaluate(() => qa.state.mode), 'independent');
  await page.click('[aria-label="关闭下载提示"]');
  await page.evaluate(() => {qa.openError='native-host-forbidden';});
  await page.click('.mac-launch');
  assert.equal(await page.evaluate(() => !!document.querySelector('.mac-download-notice')), false);
  await page.evaluate(() => {qa.state={mode:'native',available:false,connectionError:'native-host-missing'};});
  await page.waitForSelector('.connection-panel a');
  assert.ok(await page.evaluate(() => document.querySelector('.connection-panel').textContent.includes('已安装')));
  await page.evaluate(() => {qa.state={mode:'native',available:true,unlocked:false,paired:true};});
  await page.waitForFunction(() => document.querySelector('.connection-panel h2')?.textContent === '在 Mac 上解锁');
  assert.equal(await page.evaluate(() => !!document.querySelector('.connection-panel a')), false);
  return ['header version matches package metadata', 'Mac launch dispatches without switching vault mode', 'missing host offers GitHub download and registration guidance', 'permission failure and locked Mac do not claim missing installation'];
}
