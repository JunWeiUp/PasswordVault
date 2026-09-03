const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');

function loadHelpers(locale) {
  const messages = JSON.parse(fs.readFileSync(path.join(root, `chrome/_locales/${locale}/messages.json`)));
  const source = fs.readFileSync(path.join(root, 'chrome/content.js'), 'utf8').split('// Content script')[0];
  const context = { chrome: { i18n: { getMessage: (key, values = []) => messages[key].message.replace(/\$(\d+)/g, (_, n) => values[n - 1]) } } };
  vm.createContext(context);
  vm.runInContext(source + '\nthis.messageHtml = messageHtml; this.escapeHtml = escapeHtml;', context);
  return context;
}

test('account names cannot inject markup into autofill/save prompts', () => {
  const ui = loadHelpers('en');
  const malicious = '<img src=x onerror="alert(1)">&\'example';
  const message = ui.messageHtml('savePasswordFor', [malicious]);
  assert.ok(message.includes('&lt;img'));
  assert.ok(message.includes('&quot;'));
  assert.ok(message.includes('&#39;'));
  assert.ok(!message.includes('<img'));
  assert.equal(ui.escapeHtml('normal@example.com'), 'normal@example.com');
});

test('English fallback and Chinese substitution produce complete messages', () => {
  assert.equal(loadHelpers('en').messageHtml('fillAccount', ['Alex']), 'Fill: Alex');
  assert.equal(loadHelpers('zh_CN').messageHtml('fillAccount', ['Alex']), '填充：Alex');
  assert.ok(loadHelpers('en').messageHtml('openVault').includes('PasswordVault'));
});
