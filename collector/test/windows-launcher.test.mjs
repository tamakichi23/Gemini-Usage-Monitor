import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

test('the add-on scripts parse in Windows PowerShell 5.1 used by powershell.exe',
  { skip: process.platform !== 'win32' }, async () => {
    const launchers = [
      fileURLToPath(new URL('../../start-gemini-addon.ps1', import.meta.url)),
      fileURLToPath(new URL('../../install-gemini-addon.ps1', import.meta.url)),
      fileURLToPath(new URL('../../package-gemini-addon.ps1', import.meta.url)),
    ];
    const executable = join(process.env.SystemRoot ?? 'C:\\Windows', 'System32',
      'WindowsPowerShell', 'v1.0', 'powershell.exe');
    const script = `
$taskTokens = $null
$taskErrors = $null
$null = [Management.Automation.Language.Parser]::ParseFile($env:GEMINI_LAUNCHER_VALIDATE, [ref]$taskTokens, [ref]$taskErrors)
[pscustomobject]@{Version=$PSVersionTable.PSVersion.ToString(); ErrorCount=@($taskErrors).Count} | ConvertTo-Json -Compress
`;
    for (const launcher of launchers) {
      const { stdout } = await promisify(execFile)(executable,
        ['-NoProfile', '-NonInteractive', '-Command', script], {
          env: { ...process.env, GEMINI_LAUNCHER_VALIDATE: launcher },
          windowsHide: true, timeout: 10_000, maxBuffer: 4096,
        });
      const result = JSON.parse(stdout);
      assert.match(result.Version, /^5\.1\./);
      assert.equal(result.ErrorCount, 0, launcher);
    }
  });
