import assert from 'node:assert/strict';
export async function run(page, base='http://127.0.0.1:4388') {
  await page.goto(base+'/tests/fixtures/signup.html');
  await page.waitForFunction(()=>qa.requests.some(r=>r.action==='login-pending'));
  const count=()=>page.evaluate(()=>qa.requests.filter(r=>r.action==='login-submitted').length);
  await page.click('form button');
  assert.equal(await count(),1);
  assert.equal(await page.evaluate(()=>qa.requests.some(r=>r.username==='fictional@example.test'&&r.password==='Fictional-signup-only')),true);
  await page.evaluate(()=>{qa.requests=[];document.querySelector('[name=confirmPassword]').value='mismatch'});
  await page.click('form button');assert.equal(await count(),0);
  await page.evaluate(()=>{qa.requests=[];for(const p of document.querySelectorAll('[type=password]')){p.autocomplete='new-password';p.value='Synthetic-new-password'}});
  await page.click('form button');assert.equal(await count(),1);
  await page.evaluate(()=>{qa.requests=[];document.querySelector('[name=password]').autocomplete='current-password'});
  await page.click('form button');assert.equal(await count(),0);
  await page.evaluate(()=>{qa.requests=[];document.querySelector('[name=password]').autocomplete='new-password';const form=document.querySelector('form');const panel=document.createElement('div');panel.innerHTML=form.innerHTML;form.replaceWith(panel);panel.querySelector('button').type='button';panel.querySelector('[name=username]').autocomplete='username'});
  await page.click('div button');assert.equal(await count(),1);
  return ['AIACC-style signup captures correct credentials','mismatched confirmation rejected','new-password confirmation supported','password-change form rejected','form-less signup supported'];
}
