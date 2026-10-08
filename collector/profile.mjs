import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { join, resolve } from 'node:path';
import { UsageError } from './parser.mjs';

const run = promisify(execFile);

// Process metadata only: return one fixed word, never command lines or credentials.
const query = String.raw`
$ErrorActionPreference = 'Stop'
$taskProfile = [IO.Path]::GetFullPath($env:GEMINI_USAGE_PROFILE_CHECK).TrimEnd('\')
foreach ($taskProcess in @(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'")) {
    if (-not $taskProcess.CommandLine -or $taskProcess.CommandLine.Contains('--type=')) { continue }
    $taskMatch = [regex]::Match($taskProcess.CommandLine, '(?:^|\s)(?:"--user-data-dir=([^"]+)"|--user-data-dir="([^"]+)"|--user-data-dir=([^\s"]+))')
    if (-not $taskMatch.Success) { continue }
    foreach ($taskIndex in 1..3) {
        if (-not $taskMatch.Groups[$taskIndex].Success) { continue }
        $taskCandidate = [IO.Path]::GetFullPath($taskMatch.Groups[$taskIndex].Value).TrimEnd('\')
        if ([string]::Equals($taskCandidate, $taskProfile, [StringComparison]::OrdinalIgnoreCase)) {
            [Console]::Out.Write('in_use')
            exit 0
        }
    }
}
[Console]::Out.Write('available')
`;

export async function assertProfileAvailable(profile, { timeoutMs = 10_000 } = {}) {
  if (process.platform !== 'win32') return;
  try {
    const executable = join(process.env.SystemRoot ?? 'C:\\Windows', 'System32',
      'WindowsPowerShell', 'v1.0', 'powershell.exe');
    const { stdout } = await run(executable, ['-NoProfile', '-NonInteractive', '-Command', query], {
      env: { ...process.env, GEMINI_USAGE_PROFILE_CHECK: resolve(profile) },
      windowsHide: true, timeout: timeoutMs, maxBuffer: 4096,
    });
    if (stdout.trim() === 'in_use') throw new UsageError('profile_in_use');
    if (stdout.trim() !== 'available') throw new UsageError('profile_check_failed');
  } catch (error) {
    if (error instanceof UsageError) throw error;
    throw new UsageError('profile_check_failed');
  }
}
