import assert from 'node:assert/strict';
export async function run(page, base = 'http://127.0.0.1:4388') {
  await page.goto(base + '/tests/fixtures/popup-confirmation.html');
  await page.waitForSelector('#capture-password');
  await page.click('text=自动锁定 · 未开启');
  const checkbox = '#browser-auto-lock';
  assert.equal(await page.evaluate(() => document.querySelector('#browser-auto-lock').checked), false);
  await page.click(checkbox);
  await page.waitForFunction(() => qa.state.autoLockEnabled === true);
  await page.selectOption('#browser-auto-lock-minutes', {label:'2 小时'});
  await page.waitForFunction(() => qa.state.autoLockMinutes === 120);
  assert.equal(await page.evaluate(() => document.querySelector('#browser-auto-lock-minutes').value), '120');
  await page.click(checkbox);
  await page.waitForFunction(() => qa.state.autoLockEnabled === false && !document.querySelector('#browser-auto-lock-minutes'));
  return ['defaults off', 'explicit opt-in', 'two-hour selection', 'disable hides duration'];
}
