param(
    [switch]$InstallStartup,
    [switch]$RemoveStartup,
    [switch]$Toggle,
    [switch]$ToggleStartup,
    [switch]$Quiet,
    [switch]$NoCollector,
    [switch]$TestWindow,
    [switch]$Launch
)

$ErrorActionPreference = 'Stop'
$taskRunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$taskStartupApprovedRunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$taskStartupApprovedFolderKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
$taskStartupName = 'Gemini Usage Monitor'
$taskStartupFolder = [Environment]::GetFolderPath('Startup')
$taskStartupShortcut = Join-Path $taskStartupFolder ($taskStartupName + '.lnk')
$taskStartMenuFolder = [Environment]::GetFolderPath('Programs')
$taskStartMenuShortcut = Join-Path $taskStartMenuFolder ($taskStartupName + '.lnk')
$taskStartupMenuShortcut = Join-Path $taskStartMenuFolder ($taskStartupName + ' - 自動起動.lnk')
$taskPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$taskLauncherExe = Join-Path $PSScriptRoot 'GeminiUsageAddon.exe'
$taskLauncherIcon = Join-Path $PSScriptRoot 'GeminiUsageAddon.ico'
$taskScript = [IO.Path]::GetFullPath($PSCommandPath)
$taskSwitchProcess = $null
$taskSwitchStopFiles = @()
$taskSwitchRestartPending = $false
$taskRefreshFile = $null

function Stop-GeminiCollectorForAccountSwitch {
    $script:taskSwitchStopFiles = @()
    $taskWatchers = @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($taskCli) -and $_.CommandLine -match '(^|\s)watch(\s|$)' })
    foreach ($taskWatcher in $taskWatchers) {
        $taskStopMatch = [regex]::Match($taskWatcher.CommandLine, '--stop-file\s+"([^"]+)"|--stop-file\s+([^\s]+)')
        if ($taskStopMatch.Success) {
            $taskStopPath = if ($taskStopMatch.Groups[1].Success) { $taskStopMatch.Groups[1].Value } else { $taskStopMatch.Groups[2].Value }
            try {
                [IO.File]::WriteAllText($taskStopPath, 'stop')
                $script:taskSwitchStopFiles += $taskStopPath
            } catch { }
        } else {
            # Only terminate a process whose command line was matched to this add-on's collector above.
            Stop-Process -Id $taskWatcher.ProcessId -ErrorAction SilentlyContinue
        }
    }
}

function Start-GeminiCollectorWorker {
    if (-not $taskNode -or -not (Test-Path -LiteralPath $taskCli -PathType Leaf)) { return }
    $taskExistingWatcher = Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($taskCli) -and $_.CommandLine -match '(^|\s)watch(\s|$)' } |
        Select-Object -First 1
    if ($taskExistingWatcher) { return }

    $script:taskStopFile = Join-Path ([IO.Path]::GetTempPath()) ('gemini-addon-stop-' + [guid]::NewGuid().ToString('N'))
    $script:taskRefreshFile = Join-Path ([IO.Path]::GetTempPath()) ('gemini-addon-refresh-' + [guid]::NewGuid().ToString('N'))
    $taskArguments = '"' + $taskCli + '" watch --interval 300 --refresh-file "' + $script:taskRefreshFile + '" --stop-file "' + $script:taskStopFile + '"'
    $script:taskWorker = Start-Process -FilePath $taskNode -ArgumentList $taskArguments -WorkingDirectory $taskCollector -WindowStyle Hidden -PassThru
    $script:taskOwnWorker = $true
}

if (-not ('GeminiAddon.DpiMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace GeminiAddon {
    public static class DpiMethods {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    }
}
'@
}
try {
    if (-not [GeminiAddon.DpiMethods]::SetProcessDpiAwarenessContext([IntPtr](-4))) {
        [void][GeminiAddon.DpiMethods]::SetThreadDpiAwarenessContext([IntPtr](-4))
    }
} catch {
    # Older Windows builds may not expose Per-Monitor V2; keep the shell child usable.
}

function Enable-GeminiAddonStartup {
    if (-not (Test-Path -LiteralPath $taskStartupFolder)) { New-Item -ItemType Directory -Path $taskStartupFolder -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $taskStartMenuFolder)) { New-Item -ItemType Directory -Path $taskStartMenuFolder -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $taskStartupApprovedFolderKey)) { New-Item -Path $taskStartupApprovedFolderKey -Force | Out-Null }
    $taskShell = New-Object -ComObject WScript.Shell
    $taskUseLauncher = Test-Path -LiteralPath $taskLauncherExe -PathType Leaf
    Remove-ItemProperty -LiteralPath $taskRunKey -Name $taskStartupName -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath $taskStartupApprovedRunKey -Name $taskStartupName -ErrorAction SilentlyContinue
    $taskStartupLink = $taskShell.CreateShortcut($taskStartupShortcut)
    $taskStartupLink.TargetPath = if ($taskUseLauncher) { $taskLauncherExe } else { $taskPowerShell }
    $taskStartupLink.Arguments = if ($taskUseLauncher) { '' } else { '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $taskScript + '"' }
    $taskStartupLink.WorkingDirectory = Split-Path -Parent $taskScript
    $taskStartupLink.WindowStyle = 7
    if (Test-Path -LiteralPath $taskLauncherIcon -PathType Leaf) { $taskStartupLink.IconLocation = $taskLauncherIcon + ',0' }
    $taskStartupLink.Save()
    $taskApprovedEnabled = [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    New-ItemProperty -LiteralPath $taskStartupApprovedFolderKey -Name ($taskStartupName + '.lnk') -Value $taskApprovedEnabled -PropertyType Binary -Force | Out-Null
    $taskStartMenuLink = $taskShell.CreateShortcut($taskStartMenuShortcut)
    $taskStartMenuLink.TargetPath = if ($taskUseLauncher) { $taskLauncherExe } else { $taskPowerShell }
    $taskStartMenuLink.Arguments = if ($taskUseLauncher) { '-Toggle' } else { '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $taskScript + '" -Toggle' }
    $taskStartMenuLink.WorkingDirectory = Split-Path -Parent $taskScript
    $taskStartMenuLink.WindowStyle = 7
    if (Test-Path -LiteralPath $taskLauncherIcon -PathType Leaf) { $taskStartMenuLink.IconLocation = $taskLauncherIcon + ',0' }
    $taskStartMenuLink.Save()
    $taskStartupMenuLink = $taskShell.CreateShortcut($taskStartupMenuShortcut)
    $taskStartupMenuLink.TargetPath = if ($taskUseLauncher) { $taskLauncherExe } else { $taskPowerShell }
    $taskStartupMenuLink.Arguments = if ($taskUseLauncher) { '-ToggleStartup' } else { '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $taskScript + '" -ToggleStartup' }
    $taskStartupMenuLink.WorkingDirectory = Split-Path -Parent $taskScript
    $taskStartupMenuLink.WindowStyle = 7
    if (Test-Path -LiteralPath $taskLauncherIcon -PathType Leaf) { $taskStartupMenuLink.IconLocation = $taskLauncherIcon + ',0' }
    $taskStartupMenuLink.Save()
}

function Disable-GeminiAddonStartup {
    Remove-Item -LiteralPath $taskStartupShortcut -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath $taskRunKey -Name $taskStartupName -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath $taskStartupApprovedRunKey -Name $taskStartupName -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath $taskStartupApprovedFolderKey -Name ($taskStartupName + '.lnk') -ErrorAction SilentlyContinue
}

function Test-GeminiAddonStartupEnabled {
    if (-not (Test-Path -LiteralPath $taskStartupShortcut -PathType Leaf)) { return $false }
    $taskApproval = Get-ItemProperty -LiteralPath $taskStartupApprovedFolderKey -Name ($taskStartupName + '.lnk') -ErrorAction SilentlyContinue
    if (-not $taskApproval) { return $true }
    $taskApprovalBytes = [byte[]]$taskApproval.($taskStartupName + '.lnk')
    return $taskApprovalBytes.Length -gt 0 -and $taskApprovalBytes[0] -eq 2
}

if ($InstallStartup) {
    Enable-GeminiAddonStartup
    if (-not $Launch) { exit 0 }
}

if ($RemoveStartup) {
    Disable-GeminiAddonStartup
    exit 0
}

if ($ToggleStartup) {
    if (Test-GeminiAddonStartupEnabled) { Disable-GeminiAddonStartup }
    else { Enable-GeminiAddonStartup }
    if (-not $Quiet) {
        Add-Type -AssemblyName System.Windows.Forms
        $taskAutoStartupMessage = if (Test-GeminiAddonStartupEnabled) { 'サインイン時に起動します。' } else { 'サインイン時には起動しません。' }
        [System.Windows.Forms.MessageBox]::Show($taskAutoStartupMessage, 'Gemini Usage Monitor', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
    exit 0
}

if ($Toggle) {
    $taskRunningUi = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.Contains($taskScript) -and $_.CommandLine -notmatch '\s-Toggle(?:\s|$)' })
    if ($taskRunningUi.Count -gt 0) {
        $taskInstalledCli = Join-Path $PSScriptRoot 'collector\cli.mjs'
        foreach ($taskUiProcess in $taskRunningUi) {
            $taskOwnedWorkers = @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" |
                Where-Object { $_.ParentProcessId -eq $taskUiProcess.ProcessId -and $_.CommandLine -and $_.CommandLine.Contains($taskInstalledCli) -and $_.CommandLine -match 'watch' })
            foreach ($taskOwnedWorker in $taskOwnedWorkers) {
                if ($taskOwnedWorker.CommandLine -match '--stop-file\s+"([^"]+)"') { [IO.File]::WriteAllText($Matches[1], 'stop') }
            }
            Stop-Process -Id $taskUiProcess.ProcessId -ErrorAction SilentlyContinue
        }
    } else {
        if (Test-Path -LiteralPath $taskLauncherExe -PathType Leaf) {
            Start-Process -FilePath $taskLauncherExe -WindowStyle Hidden | Out-Null
        } else {
            $taskLaunchArguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $taskScript + '"'
            Start-Process -FilePath $taskPowerShell -ArgumentList $taskLaunchArguments -WindowStyle Hidden | Out-Null
        }
    }
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('GeminiAddon.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
namespace GeminiAddon {
    public static class NativeMethods {
        [StructLayout(LayoutKind.Sequential)]
        public struct Rect { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)]
        public struct Point { public int X, Y; }
        public delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumWindows(EnumProc callback, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr lParam);
        [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool IsChild(IntPtr parent, IntPtr child);
        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetParent(IntPtr hwnd, IntPtr parent);
        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
        [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hwnd, int index, int value);
        [DllImport("user32.dll")] static extern int MapWindowPoints(IntPtr from, IntPtr to, ref Point point, uint count);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder className, int maxCount);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);
        [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr hwnd, uint colorKey, byte alpha, uint flags);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd, int command);

        const int GWL_STYLE = -16, GWL_EXSTYLE = -20;
        const int WS_CHILD = 0x40000000, WS_POPUP = unchecked((int)0x80000000), WS_CLIPSIBLINGS = 0x04000000;
        const int WS_EX_TOPMOST = 0x00000008, WS_EX_TOOLWINDOW = 0x00000080, WS_EX_NOACTIVATE = 0x08000000, WS_EX_LAYERED = 0x00080000;
        const uint SWP_NOSIZE = 0x0001, SWP_NOMOVE = 0x0002, SWP_NOACTIVATE = 0x0010, SWP_FRAMECHANGED = 0x0020, SWP_SHOWWINDOW = 0x0040;

        public static bool EmbedAsTaskbarChild(IntPtr hwnd, IntPtr taskbar) {
            if (hwnd == IntPtr.Zero || taskbar == IntPtr.Zero) return false;
            var style = GetWindowLong(hwnd, GWL_STYLE);
            var childStyle = (style & ~WS_POPUP) | WS_CHILD | WS_CLIPSIBLINGS;
            if (childStyle != style) SetWindowLong(hwnd, GWL_STYLE, childStyle);

            var exStyle = GetWindowLong(hwnd, GWL_EXSTYLE);
            var childExStyle = (exStyle | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE) & ~WS_EX_TOPMOST;
            if (childExStyle != exStyle) SetWindowLong(hwnd, GWL_EXSTYLE, childExStyle);

            if (GetParent(hwnd) != taskbar) {
                SetParent(hwnd, taskbar);
                if (GetParent(hwnd) != taskbar) return false;

                // Match the official surface host's Windows 11 composition rebind.
                exStyle = GetWindowLong(hwnd, GWL_EXSTYLE);
                if ((exStyle & WS_EX_LAYERED) != 0) {
                    SetWindowLong(hwnd, GWL_EXSTYLE, exStyle & ~WS_EX_LAYERED);
                    SetWindowLong(hwnd, GWL_EXSTYLE, exStyle);
                }
            }

            SetWindowPos(hwnd, IntPtr.Zero, 0, 0, 0, 0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
            return true;
        }

        public static bool PositionTaskbarChild(IntPtr hwnd, IntPtr taskbar, int screenX, int screenY,
                int width, int height, uint colorKey) {
            var point = new Point { X = screenX, Y = screenY };
            MapWindowPoints(IntPtr.Zero, taskbar, ref point, 1);
            var positioned = SetWindowPos(hwnd, IntPtr.Zero, point.X, point.Y, width, height,
                SWP_NOACTIVATE | SWP_SHOWWINDOW);
            SetLayeredWindowAttributes(hwnd, colorKey, 255, 0x00000001);
            return positioned;
        }

        public static bool HasWindowVisibleStyle(IntPtr hwnd) {
            return (GetWindowLong(hwnd, GWL_STYLE) & 0x10000000) != 0;
        }

        public static void SetWindowVisibility(IntPtr hwnd, bool visible) {
            ShowWindow(hwnd, visible ? 4 : 0); // SW_SHOWNOACTIVATE or SW_HIDE
        }

        public static bool TryFindUsageWidget(out IntPtr taskbar, out IntPtr widget, out Rect taskbarRect, out Rect widgetRect) {
            taskbar = IntPtr.Zero; widget = IntPtr.Zero;
            taskbarRect = new Rect(); widgetRect = new Rect();
            var pids = new HashSet<uint>();
            foreach (var process in Process.GetProcessesByName("claude-code-usage-monitor")) {
                try { pids.Add((uint)process.Id); } finally { process.Dispose(); }
            }
            if (pids.Count == 0) return false;

            var taskbars = new List<IntPtr>();
            EnumWindows((hwnd, _) => {
                var name = new StringBuilder(128);
                GetClassName(hwnd, name, name.Capacity);
                if (name.ToString() == "Shell_TrayWnd" || name.ToString() == "Shell_SecondaryTrayWnd") taskbars.Add(hwnd);
                return true;
            }, IntPtr.Zero);

            foreach (var candidate in taskbars) {
                IntPtr found = IntPtr.Zero;
                EnumChildWindows(candidate, (hwnd, _) => {
                    uint pid; GetWindowThreadProcessId(hwnd, out pid);
                    var name = new StringBuilder(128);
                    GetClassName(hwnd, name, name.Capacity);
                    if (pids.Contains(pid) && name.ToString() == "ClaudeCodeUsageMonitor" && IsWindowVisible(hwnd)) {
                        found = hwnd;
                        return false;
                    }
                    return true;
                }, IntPtr.Zero);
                if (found != IntPtr.Zero && GetWindowRect(candidate, out taskbarRect) && GetWindowRect(found, out widgetRect)) {
                    taskbar = candidate; widget = found; return true;
                }
            }
            return false;
        }

        public static bool TryFindPrimaryTaskbar(out IntPtr taskbar, out Rect taskbarRect, out Rect trayRect) {
            taskbar = IntPtr.Zero; trayRect = new Rect(); taskbarRect = new Rect();
            var foundTaskbar = IntPtr.Zero;
            EnumWindows((hwnd, _) => {
                var name = new StringBuilder(128);
                GetClassName(hwnd, name, name.Capacity);
                if (name.ToString() == "Shell_TrayWnd") {
                    foundTaskbar = hwnd;
                    return false;
                }
                return true;
            }, IntPtr.Zero);
            if (foundTaskbar == IntPtr.Zero || !GetWindowRect(foundTaskbar, out taskbarRect)) return false;

            taskbar = foundTaskbar;
            var foundTrayRect = new Rect();
            EnumChildWindows(taskbar, (hwnd, _) => {
                var name = new StringBuilder(128);
                GetClassName(hwnd, name, name.Capacity);
                Rect candidate;
                if (name.ToString() == "TrayNotifyWnd" && IsWindowVisible(hwnd) && GetWindowRect(hwnd, out candidate)) {
                    foundTrayRect = candidate;
                    return false;
                }
                return true;
            }, IntPtr.Zero);
            trayRect = foundTrayRect;
            return true;
        }

        public static bool DockAreaIsClear(IntPtr taskbar, IntPtr widget, IntPtr addon, Rect candidate) {
            bool blocked = false;
            EnumChildWindows(taskbar, (hwnd, _) => {
                if (hwnd == widget || hwnd == addon || IsChild(addon, hwnd) || !IsWindowVisible(hwnd)) return true;
                var name = new StringBuilder(128);
                GetClassName(hwnd, name, name.Capacity);
                var className = name.ToString();
                if (className == "Windows.UI.Composition.DesktopWindowContentBridge" ||
                    className == "Windows.UI.Input.InputSite.WindowClass" ||
                    className == "TrayDummySearchControl") return true;
                Rect other;
                if (!GetWindowRect(hwnd, out other)) return true;
                if (candidate.Left < other.Right && candidate.Right > other.Left &&
                    candidate.Top < other.Bottom && candidate.Bottom > other.Top) {
                    blocked = true;
                    return false;
                }
                return true;
            }, IntPtr.Zero);
            return !blocked;
        }

    }
}
'@
}

$taskAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [Environment]::GetFolderPath('LocalApplicationData') }
$taskDataRoot = if ($env:GEMINI_USAGE_HOME) {
    [IO.Path]::GetFullPath($env:GEMINI_USAGE_HOME)
} elseif ((Test-Path -LiteralPath (Join-Path $taskAppData 'GeminiUsageMonitor\chrome-profile') -PathType Container) -or
          -not (Test-Path -LiteralPath (Join-Path $taskAppData 'GeminiUsagePoC\chrome-profile') -PathType Container)) {
    Join-Path $taskAppData 'GeminiUsageMonitor'
} else {
    Join-Path $taskAppData 'GeminiUsagePoC'
}
$taskUsageFile = Join-Path $taskDataRoot 'usage.json'
$taskCollector = Join-Path $PSScriptRoot 'collector'
$taskCli = Join-Path $taskCollector 'cli.mjs'
$taskNode = $null
$taskWorker = $null
$taskStopFile = $null
$taskOwnWorker = $false
$taskMutex = New-Object System.Threading.Mutex($false, 'Local\GeminiUsageAddon')
$taskMutexOwned = $false
try { $taskMutexOwned = $taskMutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $taskMutexOwned = $true }
if (-not $taskMutexOwned) { $taskMutex.Dispose(); exit 0 }

try {
    if (-not $NoCollector) {
        if (-not (Test-Path -LiteralPath $taskCli)) { throw 'The Gemini collector package is missing.' }
        $taskNode = (Get-Command node -ErrorAction Stop).Source
        $taskExistingWorker = Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($taskCli) -and $_.CommandLine -match '(^|\s)watch(\s|$)' } |
            Select-Object -First 1
        if ($taskExistingWorker) {
            $taskRefreshMatch = [regex]::Match($taskExistingWorker.CommandLine, '--refresh-file\s+"([^"]+)"|--refresh-file\s+([^\s]+)')
            if ($taskRefreshMatch.Success) {
                $taskRefreshFile = if ($taskRefreshMatch.Groups[1].Success) { $taskRefreshMatch.Groups[1].Value } else { $taskRefreshMatch.Groups[2].Value }
            }
        } else {
            Start-GeminiCollectorWorker
        }
    }

    $taskForm = New-Object System.Windows.Forms.Form
    if ($TestWindow) {
        $taskForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedToolWindow
        $taskForm.ShowInTaskbar = $true
        $taskForm.BackColor = [System.Drawing.Color]::FromArgb(28, 29, 34)
    } else {
        $taskForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
        $taskForm.ShowInTaskbar = $false
        $taskForm.BackColor = [System.Drawing.Color]::FromArgb(26, 33, 60)
        $taskForm.TransparencyKey = $taskForm.BackColor
    }
    $taskForm.TopMost = $false
    $taskForm.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $taskForm.Text = 'Gemini Usage Monitor'
    $taskForm.ClientSize = New-Object System.Drawing.Size(148, 46)
    $taskForm.Opacity = 1.0
    $taskForm.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

    $taskSessionSegments = [System.Collections.Generic.List[System.Windows.Forms.Panel]]::new()
    $taskWeeklySegments = [System.Collections.Generic.List[System.Windows.Forms.Panel]]::new()
    for ($taskSegmentIndex = 0; $taskSegmentIndex -lt 5; $taskSegmentIndex++) {
        $taskSessionSegment = New-Object System.Windows.Forms.Panel
        $taskSessionSegment.Location = New-Object System.Drawing.Point((11 * $taskSegmentIndex), 11)
        $taskSessionSegment.Size = New-Object System.Drawing.Size(10, 9)
        $taskSessionSegment.BackColor = [System.Drawing.Color]::FromArgb(68, 68, 68)
        $taskForm.Controls.Add($taskSessionSegment)
        $taskSessionSegments.Add($taskSessionSegment)

        $taskWeeklySegment = New-Object System.Windows.Forms.Panel
        $taskWeeklySegment.Location = New-Object System.Drawing.Point((11 * $taskSegmentIndex), 27)
        $taskWeeklySegment.Size = New-Object System.Drawing.Size(10, 9)
        $taskWeeklySegment.BackColor = [System.Drawing.Color]::FromArgb(68, 68, 68)
        $taskForm.Controls.Add($taskWeeklySegment)
        $taskWeeklySegments.Add($taskWeeklySegment)
    }

    $taskSessionLabel = New-Object System.Windows.Forms.Label
    $taskSessionLabel.Location = New-Object System.Drawing.Point(62, 9)
    $taskSessionLabel.Size = New-Object System.Drawing.Size(83, 13)
    $taskSessionLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.0)
    $taskSessionLabel.BackColor = [System.Drawing.Color]::Transparent
    $taskSessionLabel.ForeColor = [System.Drawing.Color]::FromArgb(196, 181, 253)
    $taskSessionLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $taskSessionLabel.Text = '--% · --'
    $taskForm.Controls.Add($taskSessionLabel)

    $taskWeeklyLabel = New-Object System.Windows.Forms.Label
    $taskWeeklyLabel.Location = New-Object System.Drawing.Point(62, 25)
    $taskWeeklyLabel.Size = New-Object System.Drawing.Size(83, 13)
    $taskWeeklyLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.0)
    $taskWeeklyLabel.BackColor = [System.Drawing.Color]::Transparent
    $taskWeeklyLabel.ForeColor = [System.Drawing.Color]::FromArgb(196, 181, 253)
    $taskWeeklyLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $taskWeeklyLabel.Text = '--% · --'
    $taskForm.Controls.Add($taskWeeklyLabel)

    $taskBorder = New-Object System.Windows.Forms.Panel
    $taskBorder.Dock = [System.Windows.Forms.DockStyle]::Fill
    $taskBorder.BackColor = [System.Drawing.Color]::Transparent
    $taskBorder.Enabled = $false
    $taskForm.Controls.Add($taskBorder)
    $taskBorder.SendToBack()

    $taskMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $taskRefreshItem = New-Object System.Windows.Forms.ToolStripMenuItem('今すぐ更新')
    $taskRefreshItem.Enabled = [bool]$taskRefreshFile -and [bool]$taskNode -and -not $NoCollector
    $taskRefreshItem.add_Click({
        try {
            if ([string]::IsNullOrWhiteSpace($script:taskRefreshFile)) { throw 'Refresh control is unavailable.' }
            [IO.File]::WriteAllText($script:taskRefreshFile, [DateTimeOffset]::UtcNow.ToString('o'))
            $taskNotify.ShowBalloonTip(3500, 'Gemini使用量', '使用状況の更新を要求しました。完了まで少しお待ちください。', [System.Windows.Forms.ToolTipIcon]::Info)
        } catch {
            $taskNotify.ShowBalloonTip(5000, 'Gemini使用量を更新できませんでした', '監視プロセスが起動しているか確認してください。', [System.Windows.Forms.ToolTipIcon]::Warning)
        }
    })
    $taskMenu.Items.Add($taskRefreshItem) | Out-Null
    $taskMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $taskDisplayItem = New-Object System.Windows.Forms.ToolStripMenuItem('バーを表示')
    $taskDisplayItem.CheckOnClick = $true
    $taskDisplayItem.Checked = $true
    $taskDisplayItem.add_CheckedChanged({
        if ($taskDisplayItem.Checked) {
            $taskIsDocked = $false
            [GeminiAddon.NativeMethods]::SetWindowVisibility($taskForm.Handle, $true)
            Update-AddonPlacement
        } else {
            $taskIsDocked = $false
            [GeminiAddon.NativeMethods]::SetWindowVisibility($taskForm.Handle, $false)
        }
    })
    $taskMenu.Items.Add($taskDisplayItem) | Out-Null

    $taskSwitchItem = New-Object System.Windows.Forms.ToolStripMenuItem('Googleアカウントを切り替える')
    $taskSwitchItem.Enabled = [bool]$taskNode
    $taskSwitchItem.add_Click({
        if ($script:taskSwitchProcess -and -not $script:taskSwitchProcess.HasExited) { return }
        try {
            Stop-GeminiCollectorForAccountSwitch
            $taskSwitchItem.Enabled = $false
            $taskSwitchItem.Text = '専用Chromeを閉じると反映'
            $taskNotify.Text = 'Geminiアカウント切替中'
            $script:taskSwitchProcess = Start-Process -FilePath $taskNode `
                -ArgumentList ('"' + $taskCli + '" switch-account') `
                -WorkingDirectory $taskCollector -WindowStyle Hidden -PassThru
            $taskNotify.ShowBalloonTip(7000, 'Geminiアカウントの切り替え', '専用Chromeでアカウントを選び、Chromeウィンドウを閉じると使用量を更新します。', [System.Windows.Forms.ToolTipIcon]::Info)
        } catch {
            $taskNotify.Text = 'Gemini Usage Monitor'
            $taskSwitchItem.Enabled = $true
            $taskSwitchItem.Text = 'Googleアカウントを切り替える'
            try { if (-not $NoCollector) { Start-GeminiCollectorWorker } } catch { }
            $taskNotify.ShowBalloonTip(7000, 'Geminiアカウントを開けませんでした', '専用ChromeとNode.jsの状態を確認してください。', [System.Windows.Forms.ToolTipIcon]::Error)
        }
    })
    $taskMenu.Items.Add($taskSwitchItem) | Out-Null

    $taskStartupItem = New-Object System.Windows.Forms.ToolStripMenuItem('サインイン時に起動')
    $taskStartupItem.CheckOnClick = $true
    $taskStartupItem.Checked = Test-GeminiAddonStartupEnabled
    $taskStartupItem.add_CheckedChanged({
        if ($taskStartupItem.Checked) { Enable-GeminiAddonStartup }
        else { Disable-GeminiAddonStartup }
    })
    $taskMenu.Items.Add($taskStartupItem) | Out-Null
    $taskMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $taskOpenItem = New-Object System.Windows.Forms.ToolStripMenuItem('使用状況ページを開く')
    $taskOpenItem.add_Click({ Start-Process 'https://gemini.google.com/usage' })
    $taskMenu.Items.Add($taskOpenItem) | Out-Null
    $taskDisableItem = New-Object System.Windows.Forms.ToolStripMenuItem('アプリを無効化')
    $taskDisableItem.add_Click({ Disable-GeminiAddonStartup; $taskForm.Close() })
    $taskMenu.Items.Add($taskDisableItem) | Out-Null
    $taskExitItem = New-Object System.Windows.Forms.ToolStripMenuItem('終了')
    $taskExitItem.add_Click({ $taskForm.Close() })
    $taskMenu.Items.Add($taskExitItem) | Out-Null
    $taskNotify = New-Object System.Windows.Forms.NotifyIcon
    $taskNotify.Icon = if (Test-Path -LiteralPath $taskLauncherExe -PathType Leaf) {
        [System.Drawing.Icon]::ExtractAssociatedIcon($taskLauncherExe)
    } else { [System.Drawing.SystemIcons]::Information }
    $taskNotify.Text = 'Gemini Usage Monitor'
    $taskNotify.ContextMenuStrip = $taskMenu
    $taskNotify.Visible = $true
    $taskNotified = @{}

    $taskSwitchTimer = New-Object System.Windows.Forms.Timer
    $taskSwitchTimer.Interval = 1000
    $taskSwitchTimer.add_Tick({
        $taskActiveSwitch = $script:taskSwitchProcess
        if ($taskActiveSwitch -and $taskActiveSwitch.HasExited) {
            $taskSwitchExitCode = $taskActiveSwitch.ExitCode
            $taskActiveSwitch.Dispose()
            $script:taskSwitchProcess = $null
            $taskSwitchItem.Enabled = [bool]$taskNode
            $taskSwitchItem.Text = 'Googleアカウントを切り替える'
            $taskNotify.Text = 'Gemini Usage Monitor'
            $script:taskSwitchRestartPending = -not $NoCollector

            if ($taskSwitchExitCode -eq 0) {
                $taskNotify.ShowBalloonTip(7000, 'Gemini使用量を更新しました', '切り替え後のアカウントの使用量を表示しています。', [System.Windows.Forms.ToolTipIcon]::Info)
            } else {
                $taskNotify.ShowBalloonTip(7000, 'Gemini使用量を更新できませんでした', '専用Chromeのログイン状態を確認して、もう一度切り替えてください。', [System.Windows.Forms.ToolTipIcon]::Warning)
            }
        }

        if ($script:taskSwitchRestartPending -and -not $script:taskSwitchProcess) {
            $taskRemainingWatchers = @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" |
                Where-Object { $_.CommandLine -and $_.CommandLine.Contains($taskCli) -and $_.CommandLine -match '(^|\s)watch(\s|$)' })
            if ($taskRemainingWatchers.Count -eq 0) {
                foreach ($taskOldStopFile in $script:taskSwitchStopFiles) {
                    Remove-Item -LiteralPath $taskOldStopFile -Force -ErrorAction SilentlyContinue
                }
                $script:taskSwitchStopFiles = @()
                try {
                    Start-GeminiCollectorWorker
                    $script:taskSwitchRestartPending = $false
                } catch {
                    $taskNotify.ShowBalloonTip(7000, '使用量の監視を再開できませんでした', 'アドオンを再起動して確認してください。', [System.Windows.Forms.ToolTipIcon]::Error)
                }
            }
        }
    })
    $taskSwitchTimer.Start()

    if ($TestWindow) {
        $taskTestArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $taskForm.Location = New-Object System.Drawing.Point(($taskTestArea.Left + 20), ($taskTestArea.Top + 20))
        $taskForm.Show()
    } else {
        $taskForm.Location = New-Object System.Drawing.Point(0, 0)
    }

    function Format-ResetTime([string]$ResetAt) {
        if ([string]::IsNullOrWhiteSpace($ResetAt)) { return '--' }
        try { $taskReset = [DateTimeOffset]::Parse($ResetAt).ToUniversalTime() }
        catch { return '--' }
        $taskSpan = $taskReset - [DateTimeOffset]::UtcNow
        if ($taskSpan.TotalSeconds -le 0) { return 'now' }
        if ($taskSpan.TotalDays -ge 1) { return ('{0}d' -f [math]::Floor($taskSpan.TotalDays)) }
        if ($taskSpan.TotalHours -ge 1) { return ('{0}h' -f [math]::Floor($taskSpan.TotalHours)) }
        return ('{0}m' -f [math]::Max(1, [math]::Ceiling($taskSpan.TotalMinutes)))
    }

    function Get-TaskbarBackgroundColor([int]$X, [int]$Y, [int]$TaskbarLeft, [int]$TaskbarTop, [int]$TaskbarRight, [int]$TaskbarBottom) {
        $taskProbeX = [Math]::Max($TaskbarLeft, [Math]::Min($TaskbarRight - 1, $X))
        $taskProbeY = [Math]::Max($TaskbarTop, [Math]::Min($TaskbarBottom - 1, $Y))
        $taskPixel = New-Object System.Drawing.Bitmap(1, 1)
        $taskGraphics = [System.Drawing.Graphics]::FromImage($taskPixel)
        try {
            $taskGraphics.CopyFromScreen($taskProbeX, $taskProbeY, 0, 0, $taskPixel.Size)
            $taskSample = $taskPixel.GetPixel(0, 0)
            return [System.Drawing.Color]::FromArgb($taskSample.R, $taskSample.G, $taskSample.B)
        } catch {
            return [System.Drawing.Color]::FromArgb(26, 33, 60)
        } finally {
            $taskGraphics.Dispose()
            $taskPixel.Dispose()
        }
    }

    function Update-AddonDisplay {
        $taskSnapshot = $null
        try {
            if (Test-Path -LiteralPath $taskUsageFile) {
                $taskSnapshot = [IO.File]::ReadAllText($taskUsageFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
            }
        } catch { $taskSnapshot = $null }
        $taskFresh = $false
        if ($taskSnapshot -and $taskSnapshot.schema_version -eq 1 -and $taskSnapshot.provider -eq 'gemini_web' -and $taskSnapshot.status -eq 'ok' -and -not $taskSnapshot.stale) {
            try {
                $taskCaptured = [DateTimeOffset]::Parse($taskSnapshot.last_success_at).ToUniversalTime()
                $taskAgeMinutes = ([DateTimeOffset]::UtcNow - $taskCaptured).TotalMinutes
                $taskFresh = $taskAgeMinutes -ge 0 -and $taskAgeMinutes -le 15
            } catch { $taskFresh = $false }
        }
        foreach ($taskItem in @(
            @{ Name = '5h'; Card = if ($taskSnapshot) { $taskSnapshot.session } else { $null }; Label = $taskSessionLabel; Segments = $taskSessionSegments },
            @{ Name = '7d'; Card = if ($taskSnapshot) { $taskSnapshot.weekly } else { $null }; Label = $taskWeeklyLabel; Segments = $taskWeeklySegments }
        )) {
            $taskCard = $taskItem.Card
            if ($taskCard -and $null -ne $taskCard.remaining_percent) {
                $taskAmount = [double]$taskCard.remaining_percent
                if ($taskAmount -ge 0 -and $taskAmount -le 100) {
                    $taskPrefix = if ($taskFresh) { '' } else { '~' }
                    $taskResetText = Format-ResetTime $taskCard.resets_at
                    $taskItem.Label.Text = ('{0}{1:0}% · {2}' -f $taskPrefix, $taskAmount, $taskResetText)
                    $taskFilledSegments = [int][math]::Floor(($taskAmount / 100.0) * $taskItem.Segments.Count + 0.5)
                } else {
                    $taskItem.Label.Text = '--% · --'
                    $taskFilledSegments = 0
                }
            } else {
                $taskItem.Label.Text = '--% · --'
                $taskFilledSegments = 0
            }
            $taskActiveSegmentColor = if (-not $taskFresh) { [System.Drawing.Color]::FromArgb(104, 104, 104) }
                else { [System.Drawing.Color]::FromArgb(139, 92, 246) }
            for ($taskSegmentIndex = 0; $taskSegmentIndex -lt $taskItem.Segments.Count; $taskSegmentIndex++) {
                if ($taskSegmentIndex -lt $taskFilledSegments) { $taskItem.Segments[$taskSegmentIndex].BackColor = $taskActiveSegmentColor }
                else { $taskItem.Segments[$taskSegmentIndex].BackColor = [System.Drawing.Color]::FromArgb(68, 68, 68) }
            }
            if (-not $taskFresh) { $taskItem.Label.ForeColor = [System.Drawing.Color]::FromArgb(170, 170, 170) }
            else { $taskItem.Label.ForeColor = [System.Drawing.Color]::FromArgb(196, 181, 253) }
        }
        if (-not $taskFresh) { return }
        $taskDue = @()
        foreach ($taskWindow in @(@{ Name = '5h'; Card = $taskSnapshot.session }, @{ Name = 'weekly'; Card = $taskSnapshot.weekly })) {
            if (-not $taskWindow.Card -or [string]::IsNullOrWhiteSpace($taskWindow.Card.resets_at)) { continue }
            try { $taskReset = [DateTimeOffset]::Parse($taskWindow.Card.resets_at).ToUniversalTime() }
            catch { continue }
            $taskMinutes = ($taskReset - [DateTimeOffset]::UtcNow).TotalMinutes
            $taskRemaining = [double]$taskWindow.Card.remaining_percent
            if ($taskRemaining -gt 0.01 -and $taskMinutes -gt 0 -and $taskMinutes -le 30) {
                $taskKey = $taskWindow.Name + '|' + $taskReset.ToString('o')
                if (-not $taskNotified.ContainsKey($taskKey)) { $taskDue += @{ Key = $taskKey; Minutes = $taskMinutes; Remaining = $taskRemaining } }
            }
        }
        $taskNextNotice = $taskDue | Sort-Object Minutes | Select-Object -First 1
        if ($taskNextNotice) {
            $taskNotified[$taskNextNotice.Key] = $true
            $taskResetText = if ($taskNextNotice.Minutes -lt 1) { 'less than 1m' } else { ('{0}m' -f [math]::Ceiling($taskNextNotice.Minutes)) }
            $taskNotify.ShowBalloonTip(8000, '利用枠のリセットが近づいています', ('残り{0:0}%です。あと{1}でリセットされます。' -f $taskNextNotice.Remaining, $taskResetText), [System.Windows.Forms.ToolTipIcon]::Info)
        }
    }

    $taskTimer = New-Object System.Windows.Forms.Timer
    $taskTimer.Interval = 15000
    $taskTimer.add_Tick({ Update-AddonDisplay })

    function Update-AddonPlacement {
        if (-not $taskDisplayItem.Checked) {
            $script:taskIsDocked = $false
            [GeminiAddon.NativeMethods]::SetWindowVisibility($taskForm.Handle, $false)
            return
        }
        if ($TestWindow) { return }

        $taskbarHwnd = [IntPtr]::Zero
        $taskWidgetHwnd = [IntPtr]::Zero
        $taskbarRect = New-Object GeminiAddon.NativeMethods+Rect
        $taskWidgetRect = New-Object GeminiAddon.NativeMethods+Rect
        $taskFoundWidget = [GeminiAddon.NativeMethods]::TryFindUsageWidget(
            [ref]$taskbarHwnd, [ref]$taskWidgetHwnd, [ref]$taskbarRect, [ref]$taskWidgetRect)
        $taskTrayRect = New-Object GeminiAddon.NativeMethods+Rect
        if (-not $taskFoundWidget -and -not [GeminiAddon.NativeMethods]::TryFindPrimaryTaskbar(
            [ref]$taskbarHwnd, [ref]$taskbarRect, [ref]$taskTrayRect)) {
            [GeminiAddon.NativeMethods]::SetWindowVisibility($taskForm.Handle, $false)
            $script:taskIsDocked = $false
            return
        }

        $taskbarWidth = $taskbarRect.Right - $taskbarRect.Left
        $taskbarHeight = $taskbarRect.Bottom - $taskbarRect.Top
        $taskWidgetHeight = if ($taskFoundWidget) { $taskWidgetRect.Bottom - $taskWidgetRect.Top } else { $taskbarHeight }
        $taskScreenBounds = [System.Windows.Forms.Screen]::FromHandle($taskbarHwnd).Bounds
        if ($taskbarWidth -le ($taskbarHeight + 100)) {
            [GeminiAddon.NativeMethods]::SetWindowVisibility($taskForm.Handle, $false)
            $script:taskIsDocked = $false
            return
        }

        $taskAddonWidth = $taskForm.Width
        $taskAddonHeight = [Math]::Min($taskWidgetHeight, $taskForm.Height)
        $taskGap = 12
        $taskCandidate = New-Object GeminiAddon.NativeMethods+Rect
        if ($taskFoundWidget) {
            $taskCandidate.Left = $taskWidgetRect.Left - $taskAddonWidth - $taskGap
            $taskCandidate.Top = $taskWidgetRect.Top
        } else {
            $taskCandidate.Left = $taskbarRect.Right - $taskAddonWidth - 4
            $taskCandidate.Top = $taskbarRect.Top + [int][Math]::Floor(($taskbarHeight - $taskAddonHeight) / 2.0)
        }
        $taskCandidate.Right = $taskCandidate.Left + $taskAddonWidth
        $taskCandidate.Bottom = $taskCandidate.Top + $taskAddonHeight

        $taskInsideTaskbar = $taskCandidate.Left -ge $taskbarRect.Left -and $taskCandidate.Right -le $taskbarRect.Right -and
            $taskCandidate.Top -ge $taskbarRect.Top -and $taskCandidate.Bottom -le $taskbarRect.Bottom
        $taskAreaClear = $taskInsideTaskbar -and [GeminiAddon.NativeMethods]::DockAreaIsClear($taskbarHwnd, $taskWidgetHwnd, $taskForm.Handle, $taskCandidate)

        if ($taskFoundWidget -and -not $taskAreaClear) {
            $taskCandidate.Left = $taskWidgetRect.Right
            $taskCandidate.Right = $taskCandidate.Left + $taskAddonWidth
            $taskInsideTaskbar = $taskCandidate.Left -ge $taskbarRect.Left -and $taskCandidate.Right -le $taskbarRect.Right
            $taskAreaClear = $taskInsideTaskbar -and [GeminiAddon.NativeMethods]::DockAreaIsClear($taskbarHwnd, $taskWidgetHwnd, $taskForm.Handle, $taskCandidate)
        }

        if (-not $taskAreaClear) {
            $taskCandidate.Top = $taskbarRect.Top + [int][Math]::Floor(($taskbarHeight - $taskAddonHeight) / 2.0)
            $taskCandidate.Left = $taskbarRect.Right - $taskAddonWidth - 4
            $taskCandidate.Right = $taskCandidate.Left + $taskAddonWidth
            while ($taskCandidate.Left -ge ($taskbarRect.Left + 4)) {
                $taskCandidate.Bottom = $taskCandidate.Top + $taskAddonHeight
                $taskInsideTaskbar = $taskCandidate.Left -ge $taskbarRect.Left -and $taskCandidate.Right -le $taskbarRect.Right
                if ($taskInsideTaskbar -and [GeminiAddon.NativeMethods]::DockAreaIsClear($taskbarHwnd, $taskWidgetHwnd, $taskForm.Handle, $taskCandidate)) {
                    $taskAreaClear = $true
                    break
                }
                $taskCandidate.Left -= 8
                $taskCandidate.Right -= 8
            }
        }

        if (-not $taskAreaClear) {
            [GeminiAddon.NativeMethods]::SetWindowVisibility($taskForm.Handle, $false)
            $script:taskIsDocked = $false
            return
        }

        $taskNeedsDockUpdate = -not $script:taskIsDocked -or
            $script:taskCurrentDockX -ne $taskCandidate.Left -or $script:taskCurrentDockY -ne $taskCandidate.Top
        if (-not [GeminiAddon.NativeMethods]::EmbedAsTaskbarChild($taskForm.Handle, $taskbarHwnd)) {
            [GeminiAddon.NativeMethods]::SetWindowVisibility($taskForm.Handle, $false)
            $script:taskIsDocked = $false
            return
        }

        $taskCandidateVisible = $taskCandidate.Left -ge $taskScreenBounds.Left -and
            $taskCandidate.Right -le $taskScreenBounds.Right -and
            $taskCandidate.Top -ge $taskScreenBounds.Top -and
            $taskCandidate.Bottom -le $taskScreenBounds.Bottom
        $taskRefreshBackground = $taskNeedsDockUpdate -or
            ([DateTimeOffset]::UtcNow - $script:taskLastBackgroundSample).TotalSeconds -ge 2
        if ($taskRefreshBackground -and $taskCandidateVisible -and -not $TestWindow) {
            $taskBackground = Get-TaskbarBackgroundColor ($taskCandidate.Left + [int][Math]::Floor($taskAddonWidth / 2.0)) ($taskCandidate.Top + [int][Math]::Floor($taskAddonHeight / 2.0)) `
                $taskbarRect.Left $taskbarRect.Top $taskbarRect.Right $taskbarRect.Bottom
            if ($taskForm.TransparencyKey.ToArgb() -ne $taskBackground.ToArgb()) {
                $taskForm.BackColor = $taskBackground
                $taskForm.TransparencyKey = $taskBackground
            }
            $script:taskLastBackgroundSample = [DateTimeOffset]::UtcNow
        }
        if (-not [GeminiAddon.NativeMethods]::HasWindowVisibleStyle($taskForm.Handle)) {
            [GeminiAddon.NativeMethods]::SetWindowVisibility($taskForm.Handle, $true)
        }
        $taskColorKey = [uint32]($taskForm.TransparencyKey.R -bor ($taskForm.TransparencyKey.G -shl 8) -bor ($taskForm.TransparencyKey.B -shl 16))
        if (-not [GeminiAddon.NativeMethods]::PositionTaskbarChild(
            $taskForm.Handle, $taskbarHwnd, $taskCandidate.Left, $taskCandidate.Top,
            $taskAddonWidth, $taskAddonHeight, $taskColorKey)) {
            [GeminiAddon.NativeMethods]::SetWindowVisibility($taskForm.Handle, $false)
            $script:taskIsDocked = $false
            return
        }
        $script:taskCurrentDockX = $taskCandidate.Left
        $script:taskCurrentDockY = $taskCandidate.Top
        $script:taskIsDocked = $true
    }

    $taskDockTimer = New-Object System.Windows.Forms.Timer
    $taskDockTimer.Interval = 500
    $taskDockTimer.add_Tick({ Update-AddonPlacement })
    $taskIsDocked = $false
    $taskCurrentDockX = [int]::MinValue
    $taskCurrentDockY = [int]::MinValue
    $script:taskLastBackgroundSample = [DateTimeOffset]::MinValue
    Update-AddonPlacement
    Update-AddonDisplay
    $taskDockTimer.Start()
    $taskTimer.Start()
    $taskForm.add_FormClosed({ [System.Windows.Forms.Application]::ExitThread() })
    [System.Windows.Forms.Application]::Run()
} finally {
    if ($taskTimer) { $taskTimer.Stop(); $taskTimer.Dispose() }
    if ($taskDockTimer) { $taskDockTimer.Stop(); $taskDockTimer.Dispose() }
    if ($taskSwitchTimer) { $taskSwitchTimer.Stop(); $taskSwitchTimer.Dispose() }
    if ($taskSwitchProcess -and -not $taskSwitchProcess.HasExited) {
        try { $taskSwitchProcess.Kill() } catch { }
        $taskSwitchProcess.Dispose()
    }
    if ($taskNotify) { $taskNotify.Visible = $false; $taskNotify.Dispose() }
    if ($taskMenu) { $taskMenu.Dispose() }
    if ($taskForm) { $taskForm.Dispose() }
    if ($taskOwnWorker -and $taskWorker -and -not $taskWorker.HasExited) {
        [IO.File]::WriteAllText($taskStopFile, 'stop')
        $null = $taskWorker.WaitForExit(15000)
        if (-not $taskWorker.HasExited) {
            $taskOwnedProcess = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $taskWorker.Id)
            if ($taskOwnedProcess.CommandLine -and $taskOwnedProcess.CommandLine.Contains($taskCli)) {
                Stop-Process -Id $taskWorker.Id -ErrorAction SilentlyContinue
            }
        }
        Remove-Item -LiteralPath $taskStopFile -ErrorAction SilentlyContinue
    }
    if ($taskMutexOwned) { $taskMutex.ReleaseMutex() }
    $taskMutex.Dispose()
}
