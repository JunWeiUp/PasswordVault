import assert from 'node:assert/strict';

export async function run(page, base = 'http://127.0.0.1:4388') {
  const load = async () => {
    await page.goto(base + '/tests/fixtures/shadow-login.html');
    await page.waitForFunction(() => qa.requests.some(request => request.action === 'login-pending'));
    await page.fill('input[name=username]', 'fictional@example.test');
    await page.fill('input[name=password]', 'Synthetic-only-password');
    await page.click('#outside');
    await page.waitForFunction(() => !!document.querySelector('[popover]'));
  };
  const count = action => page.evaluate(action => qa.requests.filter(request => request.action === action).length, action);
  await load();
  await page.click('loc=role:button[name="保存"]');
  assert.equal(await count('login-save'), 1);
  assert.equal(await count('login-open'), 0);
  await page.click('loc=role:button[name="修改账号密码"]');
  assert.equal(await count('login-open'), 1);
  assert.equal(await page.evaluate(() => qa.requests.find(request => request.action === 'login-open').saved), true);
  await load();
  await page.evaluate(() => { qa.saveFailure = true; });
  await page.click('loc=role:button[name="保存"]');
  assert.equal(await count('login-open'), 0);
  await page.evaluate(() => { qa.saveFailure = false; qa.queued = true; });
  await page.click('loc=role:button[name="重试保存"]');
  assert.equal(await count('login-save'), 2);
  assert.equal(await count('login-open'), 0);
  return ['save stays on page', 'editing opens only on request', 'failed save can retry', 'offline save stays on page'];
}
