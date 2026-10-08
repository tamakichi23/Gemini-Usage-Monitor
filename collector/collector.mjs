import { chromium } from 'playwright-core';
import { UsageError, parseUsage } from './parser.mjs';
import { assertProfileAvailable } from './profile.mjs';

export const USAGE_URL = 'https://gemini.google.com/usage';

// Also used by the DOM fixture test; it reads no cookies, application state, or scripts.
export function readUsageDOM() {
  const lines = selector => {
    const cards = document.querySelectorAll(selector);
    return cards.length === 1 ? cards[0].innerText.split(/\n/).map(s => s.trim()).filter(Boolean) : null;
  };
  return {
    captured_at: new Date().toISOString(),
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    session_lines: lines('[data-test-id="gxu-currently"]'),
    weekly_lines: lines('[data-test-id="gxu-weekly"]'),
  };
}

export async function launchCollector(profile, { profileCheckTimeoutMs = 10_000 } = {}) {
  await assertProfileAvailable(profile, { timeoutMs: profileCheckTimeoutMs });
  return chromium.launchPersistentContext(profile, {
    channel: 'chrome', headless: true, locale: 'ja-JP', timezoneId: 'Asia/Tokyo',
    chromiumSandbox: true, ignoreHTTPSErrors: false, acceptDownloads: false,
    timeout: 20_000,
  });
}

export async function collect(context, timeout = 25_000) {
  const page = await context.newPage();
  page.setDefaultTimeout(timeout);
  try {
    const response = await page.goto(USAGE_URL, { waitUntil: 'domcontentloaded', timeout });
    if (new URL(page.url()).hostname === 'accounts.google.com' || response?.status() === 401) {
      throw new UsageError('auth_required');
    }
    if (response && response.status() >= 400) throw new UsageError('request_failed');
    await page.waitForFunction(() => {
      const usage = document.querySelector('[data-test-id="gxu-currently"], [data-test-id="gxu-weekly"]');
      const text = usage?.innerText ?? '';
      return /[%％]/.test(text) || location.hostname === 'accounts.google.com' ||
        document.querySelector('a[href*="accounts.google.com/ServiceLogin"]');
    }, null, { timeout });
    if (new URL(page.url()).hostname === 'accounts.google.com' ||
        await page.locator('a[href*="accounts.google.com/ServiceLogin"]').count()) {
      throw new UsageError('auth_required');
    }
    return parseUsage(await page.evaluate(readUsageDOM));
  } finally {
    await page.close().catch(() => {});
  }
}
