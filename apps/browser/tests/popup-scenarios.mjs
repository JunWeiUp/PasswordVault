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
  await page.evaluate(() => { qa.state.unlocked=false; });
  await page.waitForFunction(() => !document.querySelector('#capture-password'));
  assert.equal(await page.evaluate(() => !document.querySelector('#capture-password')), true);
  results.push('locking removes captured credentials from the UI');
  await load();
  await page.evaluate(() => { qa.state.mode='independent'; }); await poll();
  await page.click('.capture .actions button[type="button"]');
  await page.waitForSelector('.capture', {state:'detached'});
  await page.click('button.wide');
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
  assert.equal(await page.evaluate(() => document.querySelector('[role=alert]').textContent.includes('更新 Mac') && !document.querySelector('[role=status]')), true);
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
