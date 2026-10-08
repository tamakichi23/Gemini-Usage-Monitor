import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { spawn } from 'node:child_process';
import { parseArgs } from 'node:util';
import { setTimeout as delay } from 'node:timers/promises';
import { collect, launchCollector, USAGE_URL } from './collector.mjs';
import { accountSwitchSnapshot, failureSnapshot, parseUsage, UsageError } from './parser.mjs';
import { classify } from './diagnostics.mjs';
import { assertProfileAvailable } from './profile.mjs';

const { values, positionals } = parseArgs({ allowPositionals: true, options: {
  profile: { type: 'string' }, out: { type: 'string' }, fixture: { type: 'string' },
  interval: { type: 'string', default: '300' },
  'stop-file': { type: 'string' },
} });
const appData = process.env.LOCALAPPDATA ?? join(homedir(), '.local', 'share');
const appRoot = join(appData, 'GeminiUsageMonitor');
const legacyRoot = join(appData, 'GeminiUsagePoC');
const root = resolve(process.env.GEMINI_USAGE_HOME ?? (
  existsSync(join(appRoot, 'chrome-profile')) || !existsSync(join(legacyRoot, 'chrome-profile'))
    ? appRoot : legacyRoot
));
const profile = resolve(values.profile ?? join(root, 'chrome-profile'));
const out = resolve(values.out ?? join(root, 'usage.json'));
const command = positionals[0] ?? 'collect';

async function publish(snapshot) {
  await mkdir(dirname(out), { recursive: true });
  const temp = `${out}.${process.pid}.tmp`;
  await writeFile(temp, JSON.stringify(snapshot, null, 2) + '\n', { mode: 0o600 });
  await rename(temp, out);
  process.stdout.write(JSON.stringify(snapshot) + '\n');
}

async function previousSnapshot() {
  try { return JSON.parse(await readFile(out, 'utf8')); } catch { return null; }
}

async function login() {
  if (process.platform !== 'win32') throw new UsageError('windows_login_only');
  const executable = [process.env.PROGRAMFILES, process.env['PROGRAMFILES(X86)'], process.env.LOCALAPPDATA]
    .filter(Boolean).map(p => join(p, 'Google', 'Chrome', 'Application', 'chrome.exe')).find(existsSync);
  if (!executable) throw new UsageError('chrome_not_found');
  await mkdir(profile, { recursive: true });
  // Intentionally visible: this window is the user's interactive Google sign-in.
  // Normal Chrome with no automation/debugging switches avoids automation login rejection.
  const child = spawn(executable, [`--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check', '--disable-background-mode', USAGE_URL], {
    detached: true, windowsHide: false, stdio: 'ignore',
  });
  await new Promise((done, reject) => { child.once('spawn', done); child.once('error', reject); });
  child.unref();
  process.stdout.write('専用ChromeでGoogleにログインし、使用量が表示されたら専用ウィンドウをすべて閉じてください。\n');
}

async function waitForDedicatedChromeToClose() {
  let profileWasOpen = false;
  const launchDeadline = Date.now() + 15_000;
  while (true) {
    try {
      await assertProfileAvailable(profile);
      if (profileWasOpen) return;
      if (Date.now() >= launchDeadline) throw new UsageError('profile_open_failed');
    } catch (error) {
      if (!(error instanceof UsageError) || error.code !== 'profile_in_use') throw error;
      profileWasOpen = true;
    }
    await delay(1000);
  }
}

async function switchAccount() {
  // Let an in-flight poll release the shared Chrome profile before opening it visibly.
  const profileDeadline = Date.now() + 30_000;
  while (true) {
    try {
      await assertProfileAvailable(profile);
      break;
    } catch (error) {
      if (!(error instanceof UsageError) || error.code !== 'profile_in_use') throw error;
      if (Date.now() >= profileDeadline) throw new UsageError('profile_busy');
      await delay(500);
    }
  }

  // Do not leave the previous account's cached quota visible during the switch.
  await publish(accountSwitchSnapshot());
  await login();
  await waitForDedicatedChromeToClose();
  if (!await cycle()) process.exitCode = 2;
}

async function cycle() {
  let context;
  let stage = 'launch';
  try {
    context = await launchCollector(profile);
    stage = 'collect';
    const snapshot = await collect(context);
    stage = 'publish';
    await publish(snapshot);
    return true;
  } catch (error) {
    const status = classify(error, stage);
    await publish(failureSnapshot(status, await previousSnapshot()));
    if (status === 'profile_in_use') {
      process.stderr.write('Gemini専用Chromeが使用中です。ログイン用ウィンドウをすべて閉じ、watch実行中なら手動collectを止めてください。\n');
    }
    return false;
  } finally {
    if (context) await context.close().catch(() => {});
  }
}

try {
  if (command === 'login') await login();
  else if (command === 'switch-account') await switchAccount();
  else if (command === 'fixture') {
    if (!values.fixture) throw new UsageError('fixture_path_required');
    await publish(parseUsage(JSON.parse(await readFile(values.fixture, 'utf8'))));
  } else if (command === 'collect') {
    if (!await cycle()) process.exitCode = 2;
  } else if (command === 'watch') {
    const seconds = Number(values.interval);
    if (!Number.isFinite(seconds) || seconds < 60 || seconds > 86400) throw new UsageError('invalid_interval');
    const controller = new AbortController();
    process.once('SIGINT', () => controller.abort());
    process.once('SIGTERM', () => controller.abort());
    const stopped = () => controller.signal.aborted || (values['stop-file'] && existsSync(values['stop-file']));
    while (!stopped()) {
      await cycle();
      const next = Date.now() + seconds * 1000;
      while (!stopped() && Date.now() < next) {
        await delay(Math.min(1000, next - Date.now()), null, { signal: controller.signal }).catch(() => {});
      }
    }
  } else throw new UsageError('unknown_command');
} catch (error) {
  process.stderr.write(JSON.stringify({ status: classify(error) }) + '\n');
  process.exitCode = 2;
}
