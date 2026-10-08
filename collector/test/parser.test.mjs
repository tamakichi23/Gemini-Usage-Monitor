import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { accountSwitchSnapshot, failureSnapshot, parseReset, parseUsage } from '../parser.mjs';

const synthetic = JSON.parse(await readFile(new URL('../fixtures/synthetic-ja.json', import.meta.url), 'utf8'));

test('synthetic Japanese usage: 0% remaining is distinguishable from missing', () => {
  const data = parseUsage(synthetic);
  assert.equal(data.session.remaining_percent, 58);
  assert.equal(data.weekly.remaining_percent, 75);
  assert.equal(data.session.resets_at, '2026-01-15T06:40:00.000Z');
  assert.equal(data.weekly.resets_at, '2026-01-20T06:40:00.000Z');
});

test('missing weekly card remains unknown, never 100% remaining', () => {
  assert.equal(parseUsage({ ...synthetic, weekly_lines: null }).weekly, null);
});

test('unrecognized format fails without inventing 0% usage', () => {
  for (const lines of [['現在の使用量', '読み込み中'], ['101% 使用中'], ['-2% 使用中'], ['2% used', '50% used']]) {
    assert.throws(() => parseUsage({ ...synthetic, session_lines: lines }));
  }
});

test('missing or unrecognized reset retains valid percentage with null timestamp', () => {
  const data = parseUsage({ ...synthetic, session_lines: ['2% 使用中', 'リセット: 後ほど'] });
  assert.equal(data.session.remaining_percent, 98);
  assert.equal(data.session.resets_at, null);
});

test('decimal percentages and English used labels', () => {
  assert.equal(parseUsage({ ...synthetic, session_lines: ['2.5% used', 'Resets at 1:40 AM'] }).session.remaining_percent, 97.5);
});

test('host timezone cannot silently change interpreted timestamps', () => {
  assert.throws(() => parseUsage({ ...synthetic, timezone: 'America/Los_Angeles' }));
});

test('JST midnight rolls time-only reset into next day', () => {
  assert.equal(parseReset('0:40にリセット', '2026-10-06T14:59:00Z', 'session'), '2026-10-06T15:40:00.000Z');
});

test('yearless weekly reset handles New Year', () => {
  assert.equal(parseReset('1月2日の15:40にリセット', '2026-12-31T00:00:00Z', 'weekly'), '2027-01-02T06:40:00.000Z');
});

test('invalid or implausible reset times are never presented as confirmed', () => {
  for (const text of ['2月30日の1:40にリセット', '25:40にリセット', '1:99にリセット', '10月20日の1:40にリセット']) {
    assert.equal(parseReset(text, synthetic.captured_at, 'session'), null);
  }
  assert.equal(parseReset('0:30にリセット', synthetic.captured_at, 'session'), null);
});

test('failure preserves last valid reading explicitly as stale', () => {
  const good = parseUsage(synthetic);
  const failed = failureSnapshot('auth_required', good, '2026-10-06T15:55:00Z');
  assert.equal(failed.status, 'auth_required');
  assert.equal(failed.stale, true);
  assert.equal(failed.last_success_at, synthetic.captured_at);
  assert.deepEqual(failed.session, good.session);
  assert.equal(failureSnapshot('timeout', null).session, null);
});

test('account switch clears cached quota until the new account is read', () => {
  const switching = accountSwitchSnapshot('2026-10-09T12:00:00.000Z');
  assert.equal(switching.status, 'account_switching');
  assert.equal(switching.stale, true);
  assert.equal(switching.last_success_at, null);
  assert.equal(switching.session, null);
  assert.equal(switching.weekly, null);

  const failed = failureSnapshot('auth_required', switching, '2026-10-09T12:01:00.000Z');
  assert.equal(failed.status, 'auth_required');
  assert.equal(failed.session, null);
  assert.equal(failed.weekly, null);
});
