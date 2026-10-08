import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chromium } from 'playwright-core';
import { readUsageDOM } from '../collector.mjs';
import { parseUsage } from '../parser.mjs';

test('headless Windows Chrome reads only usage cards, excludes sidebar and account data', async () => {
  const browser = await chromium.launch({ channel: 'chrome', headless: true, chromiumSandbox: true });
  try {
    const context = await browser.newContext({ timezoneId: 'Asia/Tokyo' });
    const page = await context.newPage();
    await page.setContent('<aside>Account secret@example.invalid 88% used</aside><div data-test-id="gxu-currently">現在の使用量<p>2% 使用中</p><p>1:40にリセット</p></div><div data-test-id="gxu-weekly">1 週間の上限<p>10月13日の15:40にリセットされます</p><p>0% 使用中</p></div>');
    const observation = await page.evaluate(readUsageDOM);
    observation.captured_at = '2026-10-06T15:52:00.000Z';
    assert.equal(JSON.stringify(observation).includes('secret@example.invalid'), false);
    assert.equal(parseUsage(observation).session.remaining_percent, 98);
    await page.setContent('<div data-test-id="gxu-currently">2% used</div><div data-test-id="gxu-currently">50% used</div>');
    const ambiguous = await page.evaluate(readUsageDOM);
    assert.throws(() => parseUsage(ambiguous));
  } finally { await browser.close(); }
});
