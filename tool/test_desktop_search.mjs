import { test } from 'node:test';
import assert from 'node:assert/strict';
import { clearSearchIndex, searchItems } from '../apps/desktop/ui/search.ts';

const account = {
  id: 'account', type: 'password', title: 'Example Work', username: 'primary',
  email: 'billing@example.test', url: 'https://example.test/login', note: '采购团队',
  tags: ['工作'], category: 'Finance', colorLabel: 'blue',
  accounts: [{ label: '紧急备用', username: 'backup-user', password: 'excluded-extra-password' }],
  customFields: [
    { label: '工号', group: '雇员', kind: 'text', value: 'EMP-2048' },
    { label: '隐藏凭据', kind: 'concealed', value: 'excluded-hidden-value' },
  ],
  passkeys: [{ rpId: 'passkeys.example.test', userName: 'passkey-user', privateKey: 'excluded-passkey-key' }],
  password: 'excluded-main-password', secret: 'excluded-totp-seed',
  passwordHistory: [{ password: 'excluded-old-password' }],
  importSource: { original: 'excluded-import-source' },
};
const ids = (items, text) => searchItems(items, text).map(item => item.id);

test('account search covers emails, additional logins, custom fields, passkey metadata and cross-field keywords', () => {
  for (const query of ['billing@', '紧急备用', 'backup-user', 'EMP-2048', '雇员', 'passkey-user', 'passkeys.example.test', '工作', 'Finance', 'blue']) {
    assert.deepEqual(ids([account], query), ['account'], query);
  }
  assert.deepEqual(ids([account], '采购 backup-user 工号'), ['account']);
  assert.deepEqual(ids([account], 'backup-user absent'), []);
  assert.deepEqual(ids([account], 'primary backup-user'), ['account']);
});

test('search never indexes secret values, history, internal IDs or arbitrary imported JSON', () => {
  const item = { ...account, privateKey: 'excluded-private-key', mnemonic: 'excluded-mnemonic' };
  for (const query of ['excluded-', 'excluded-main-password', 'excluded-extra-password', 'excluded-old-password', 'excluded-totp-seed', 'excluded-hidden-value', 'excluded-passkey-key', 'excluded-private-key', 'excluded-mnemonic', 'excluded-import-source']) {
    assert.deepEqual(ids([item], query), [], query);
  }
  assert.deepEqual(ids([item], '隐藏凭据'), ['account']);
});

test('cards, identities, authenticator issuers and crypto addresses are searchable', () => {
  const items = [
    { id: 'card', type: 'creditCard', title: 'Payment', card: { cardholder: 'Alex Fixture', brand: 'Visa', number: '4111 2222 3333 4444', securityCode: 'excluded-cvv' } },
    { id: 'identity', type: 'identity', title: 'Person', identity: { firstName: '小明', lastName: '张', company: '合成公司', email: 'identity@example.test', phone: '+86 (138) 0013-8000', address1: '测试路', address2: '10号', city: '上海', region: '浦东', postalCode: '200000', country: '中国' } },
    { id: 'code', type: 'totp', title: 'Code', issuer: 'Auth Fixture' },
    { id: 'wallet', type: 'crypto', title: 'Wallet', network: 'Ethereum', address: '0xabcdef', mnemonic: 'excluded-wallet-seed' },
  ];
  for (const query of ['Alex', 'Visa 4444', '4111222233334444']) assert.deepEqual(ids(items, query), ['card']);
  for (const query of ['张小明', '合成公司 上海', 'identity@', '13800138000', '中国 浦东 测试路 200000']) assert.deepEqual(ids(items, query), ['identity']);
  assert.deepEqual(ids(items, 'Auth Fixture'), ['code']);
  assert.deepEqual(ids(items, 'Ethereum 0xabc'), ['wallet']);
  assert.deepEqual(ids(items, 'excluded-'), []);
});

test('devices cover addresses, services, filenames and public document text while secret documents stay concealed', () => {
  const item = { id: 'device', type: 'device', title: 'Server', device: {
    host: '192.0.2.10', port: 2222, username: 'deploy', aliases: ['演示节点'], notes: '内网测试',
    password: 'excluded-device-password', privateKey: 'excluded-device-key',
    services: [{ name: 'Database', kind: 'tcp', remotePort: 5432, localPort: 15432, path: '/health' }],
    commands: [{ title: 'deploy.py', text: 'def publish_fixture(): pass', secret: false }, { title: '保密脚本', text: 'excluded-script-body', secret: true }],
    files: [{ name: '运维手册.pdf', mime: 'application/pdf', attachmentId: 'excluded-attachment-id' }],
  } };
  for (const query of ['192.0.2.10 deploy', '2222 演示节点', '内网测试', 'Database 5432', '/health', 'deploy.py publish_fixture', '运维手册.pdf', '保密脚本']) assert.deepEqual(ids([item], query), ['device'], query);
  for (const query of ['excluded-device', 'excluded-script-body', 'excluded-attachment-id']) assert.deepEqual(ids([item], query), [], query);
});

test('rich-note search covers plain body, captioned filenames and link destinations before and after opening', () => {
  const summary = { id: 'note', type: 'secureNote', title: 'Project', note: '发布计划 正文', category: '项目', __noteSearchText: 'receipt.png\n合同附件.pdf\nhttps://docs.example.test/reference' };
  const full = { ...summary, __noteSearchText: undefined, noteDocument: { type: 'doc', content: [
    { type: 'vaultImage', attrs: { name: 'receipt.png', caption: '合成图片', attachmentId: 'excluded-image-id' } },
    { type: 'vaultAttachment', attrs: { name: '合同附件.pdf' } },
    { type: 'paragraph', content: [{ type: 'text', text: '链接', marks: [{ type: 'link', attrs: { href: 'https://docs.example.test/reference' } }] }] },
  ] } };
  for (const item of [summary, full]) {
    for (const query of ['发布计划 项目', 'receipt.png', '合同附件', 'docs.example.test']) assert.deepEqual(ids([item], query), ['note']);
    assert.deepEqual(ids([item], 'excluded-image-id'), []);
  }
});

test('normalization handles case, full width, accents and arbitrary whitespace without treating punctuation as wildcards', () => {
  const item = { id: 'unicode', type: 'password', title: 'Café ＧＩＴＨＵＢ', username: 'ＡＬＥＸ', note: '中文正文' };
  for (const query of ['CAFE github', 'ｇｉｔｈｕｂ alex', '  中文正文\n\tＣＡＦÉ  ']) assert.deepEqual(ids([item], query), ['unicode']);
  assert.deepEqual(ids([item], '()*'), []);
  assert.deepEqual(ids([item], '  '), ['unicode']);
});

test('exact and prefix title matches rank above metadata matches and ties keep caller ordering', () => {
  const items = [
    { id: 'metadata', type: 'password', title: 'Other', note: 'Example' },
    { id: 'substring', type: 'password', title: 'My Example' },
    { id: 'prefix', type: 'password', title: 'Example Work' },
    { id: 'exact-a', type: 'password', title: 'Example' },
    { id: 'exact-b', type: 'password', title: 'Example' },
  ];
  assert.deepEqual(ids(items, 'example'), ['exact-a', 'exact-b', 'prefix', 'substring', 'metadata']);
  assert.deepEqual(ids(items, ''), items.map(item => item.id));
});

test('replacing an edited entry or clearing the session index cannot leave stale results', () => {
  const before = { id: 'edit', type: 'password', title: 'Before' };
  assert.deepEqual(ids([before], 'before'), ['edit']);
  const after = { ...before, title: 'After' };
  assert.deepEqual(ids([after], 'before'), []);
  assert.deepEqual(ids([after], 'after'), ['edit']);
  clearSearchIndex();
  assert.deepEqual(ids([after], 'after'), ['edit']);
});
