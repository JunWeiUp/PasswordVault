import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pollEvery } from '../apps/desktop/ui/polling.ts';
const settle = async () => { for (let i = 0; i < 4; i++) await Promise.resolve(); };

test('slow requests do not accumulate on interval ticks', async (t) => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  let calls = 0;
  let complete;
  const stop = pollEvery(100, async () => { calls++; await new Promise(resolve => { complete = resolve; }); });
  t.mock.timers.tick(100);
  t.mock.timers.tick(5000);
  assert.equal(calls, 1);
  complete(); await settle();
  t.mock.timers.tick(100);
  assert.equal(calls, 2);
  stop(); complete(); await settle();
  t.mock.timers.tick(5000);
  assert.equal(calls, 2);
});

test('a failed request is reported once and later polling still works', async (t) => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  let calls = 0, errors = 0;
  const stop = pollEvery(100, async () => { if (++calls === 1) throw new Error('fixture'); }, () => { errors++; });
  t.mock.timers.tick(100); await settle();
  assert.equal(errors, 1);
  t.mock.timers.tick(100); await settle();
  assert.equal(calls, 2); assert.equal(errors, 1);
  stop();
});

test('disposed polling cannot display a late approval or update', async (t) => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  let complete, displayed = 0;
  const stop = pollEvery(100, async (isActive) => {
    await new Promise(resolve => { complete = resolve; });
    if (isActive()) displayed++;
  });
  t.mock.timers.tick(100); stop();
  complete(); await settle(); t.mock.timers.tick(1000);
  assert.equal(displayed, 0);
});
