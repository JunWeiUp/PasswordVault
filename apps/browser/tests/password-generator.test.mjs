import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { webcrypto } from 'node:crypto';

const source = readFileSync(new URL('../src/inline-fields.ts', import.meta.url), 'utf8');
const start = source.indexOf('        const alphabet = selected.join("");');
const end = source.indexOf('        const targets =', start);
const generate = new Function('selected', 'length', 'crypto', source.slice(start, end) + 'return value;');

test('generated passwords respect length and every selected character category', () => {
  const categories = ['ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz', '0123456789', '!@#$%&*+-'];
  for (let mask = 1; mask < 16; mask++) {
    const selected = categories.filter((_, i) => mask & (1 << i));
    for (const length of [8, 24, 128]) {
      for (let repeat = 0; repeat < 10; repeat++) {
        const password = generate(selected, length, webcrypto);
        assert.equal(password.length, length);
        assert.ok([...password].every(char => selected.join('').includes(char)));
        assert.ok(selected.every(group => [...password].some(char => group.includes(char))));
      }
    }
  }
});
