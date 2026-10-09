import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { consumeRefreshRequest } from '../watch-control.mjs';

test('watch consumes a refresh signal once and ignores a missing signal', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'gemini-refresh-'));
  const signal = join(directory, 'refresh');
  try {
    assert.equal(await consumeRefreshRequest(signal), false);
    await writeFile(signal, 'refresh');
    assert.equal(await consumeRefreshRequest(signal), true);
    assert.equal(await consumeRefreshRequest(signal), false);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
