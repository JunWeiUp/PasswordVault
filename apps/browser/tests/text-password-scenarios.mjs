import assert from 'node:assert/strict';
export async function run(page, base='http://127.0.0.1:4388') {
  await page.goto(base+'/tests/fixtures/text-password-signup.html');
  await page.waitForFunction(()=>qa.requests.some(r=>r.action==='login-pending'&&r.hasPassword===true));
  const submitted=()=>page.evaluate(()=>qa.requests.filter(r=>r.action==='login-submitted'));
  await page.evaluate(()=>{const f=document.forms.signup;f.username.value='虚构用户';f.password.value='fictional-text-pass-1';f.email.value='fictional@example.test';f.email_captcha.value='123456'});
  await page.click('#signup button[type=submit]');
  let r=await submitted();
  assert.equal(r.length,1);
  assert.equal(r[0].username,'虚构用户');
  assert.equal(r[0].password,'fictional-text-pass-1');
  await page.evaluate(()=>{qa.requests=[];const f=document.forms.login;f.account.value='fictional-login';f.pwd.value='fictional-text-pass-2';f.search.value='x'});
  await page.click('#login button[type=submit]');
  r=await submitted();
  assert.equal(r.length,1);
  assert.equal(r[0].username,'fictional-login');
  assert.equal(r[0].password,'fictional-text-pass-2');
  // Generator entry for the plaintext signup password, none for captcha/search.
  await page.evaluate(()=>window.scrollTo(0,0));
  await page.click('[name=password]');
  await page.waitForFunction(()=>document.querySelectorAll('html > [popover]').length>=1);
  const hosts=await page.evaluate(()=>[...document.querySelectorAll('html > [popover]')].filter(h=>h.getBoundingClientRect().width<=32).map(h=>{const r=h.getBoundingClientRect();const el=document.elementsFromPoint(r.left+r.width/2,r.top+r.height/2).find(e=>e.tagName==='INPUT');return el?.name}));
  // An installed copy of the extension may inject its own isolated-world control too.
  assert.deepEqual([...new Set(hosts)].sort(),['password']);
  return ['plaintext signup password captured with username, not captcha','plaintext login password captured','generator entry only on plaintext new password'];
}
