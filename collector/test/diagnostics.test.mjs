import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { basename, dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { chromium } from 'playwright-core';
import { launchCollector } from '../collector.mjs';
import { assertProfileAvailable } from '../profile.mjs';
import { classify } from '../diagnostics.mjs';
import { UsageError } from '../parser.mjs';

test('failure stages expose fixed codes without browser exception details', () => {
  const privateError = new Error('private browser URL and launch arguments');
  assert.equal(classify(privateError, 'launch'), 'browser_launch_failed');
  assert.equal(classify(privateError, 'collect'), 'browser_or_network_error');
  assert.equal(classify(privateError, 'publish'), 'snapshot_write_failed');
  assert.equal(classify(privateError), 'operation_failed');
  assert.equal(classify(new UsageError('auth_required'), 'collect'), 'auth_required');
  assert.equal(classify({ name: 'TimeoutError' }, 'launch'), 'timeout');
});

test('Windows detects an occupied dedicated profile, leaves its browser running, and permits reuse after close',
  { skip: process.platform !== 'win32' }, async () => {
    const profile = await mkdtemp(join(tmpdir(), "Gemini usage O'Brien & test-"));
    let context;
    try {
      await assertProfileAvailable(profile);
      context = await chromium.launchPersistentContext(profile, {
        channel: 'chrome', headless: true, chromiumSandbox: true,
      });
      await assert.rejects(launchCollector(profile), { code: 'profile_in_use' });
      const page = await context.newPage();
      await page.setContent('<title>Still running</title>');
      assert.equal(await page.title(), 'Still running');
      await context.close();
      context = null;
      await assertProfileAvailable(profile);
    } finally {
      if (context) await context.close();
      assert.equal(dirname(resolve(profile)), resolve(tmpdir()));
      assert.ok(basename(profile).startsWith("Gemini usage O'Brien & test-"));
      await rm(profile, { recursive: true, force: true });
    }
  });
