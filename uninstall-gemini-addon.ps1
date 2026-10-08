[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param()

$ErrorActionPreference = 'Stop'
$taskInstallRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
$taskLocalAppData = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd([IO.Path]::DirectorySeparatorChar)
$taskDataRoots = @(
    [IO.Path]::GetFullPath((Join-Path $taskLocalAppData 'GeminiUsageMonitor')).TrimEnd([IO.Path]::DirectorySeparatorChar),
    [IO.Path]::GetFullPath((Join-Path $taskLocalAppData 'GeminiUsagePoC')).TrimEnd([IO.Path]::DirectorySeparatorChar)
)
$taskUninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\GeminiUsageAddon'
$taskRunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$taskStartupApprovedRunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$taskStartupApprovedFolderKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
$taskStartupName = 'Gemini Usage Monitor'
$taskStartTarget = Join-Path $taskInstallRoot 'start-gemini-addon.ps1'
$taskCliTarget = Join-Path $taskInstallRoot 'collector\cli.mjs'
$taskStartupFolder = [Environment]::GetFolderPath('Startup')
$taskProgramsFolder = [Environment]::GetFolderPath('Programs')
$taskShortcutPaths = @(
    (Join-Path $taskStartupFolder ($taskStartupName + '.lnk')),
    (Join-Path $taskProgramsFolder ($taskStartupName + '.lnk')),
    (Join-Path $taskProgramsFolder ($taskStartupName + ' - 自動起動.lnk'))
)
$taskPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

foreach ($taskDataRoot in $taskDataRoots) {
    if ($taskInstallRoot.Equals($taskDataRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $taskInstallRoot.StartsWith(($taskDataRoot + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase) -or
        $taskDataRoot.StartsWith(($taskInstallRoot + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The install path overlaps user data. Refusing to remove it.'
    }
}

if (Test-Path -LiteralPath $taskUninstallKey) {
    $taskRegisteredRoot = (Get-ItemProperty -LiteralPath $taskUninstallKey -Name InstallLocation -ErrorAction SilentlyContinue).InstallLocation
    if ($taskRegisteredRoot) {
        $taskRegisteredRoot = [IO.Path]::GetFullPath($taskRegisteredRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
        if (-not $taskRegisteredRoot.Equals($taskInstallRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The registered install path does not match this uninstaller. Refusing to remove files.'
        }
    }
}

$taskUiProcesses = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.Contains($taskStartTarget) })
foreach ($taskUiProcess in $taskUiProcesses) {
    $taskOwnedWorkers = @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" |
        Where-Object {
            $_.ParentProcessId -eq $taskUiProcess.ProcessId -and
            $_.CommandLine -and
            $_.CommandLine.Contains($taskCliTarget) -and
            $_.CommandLine -match '(^|\s)watch(\s|$)'
        })

    foreach ($taskWorker in $taskOwnedWorkers) {
        $taskStopFile = $null
        if ($taskWorker.CommandLine -match '--stop-file\s+"([^"]+)"') { $taskStopFile = $Matches[1] }
        if ($PSCmdlet.ShouldProcess(('Gemini collector PID ' + $taskWorker.ProcessId), 'Stop the add-on-owned collector')) {
            if ($taskStopFile) {
                [IO.File]::WriteAllText($taskStopFile, 'stop')
                $taskStopDeadline = [DateTime]::UtcNow.AddSeconds(15)
                do {
                    Start-Sleep -Milliseconds 250
                    $taskWorkerNow = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $taskWorker.ProcessId) -ErrorAction SilentlyContinue
                } while ($taskWorkerNow -and [DateTime]::UtcNow -lt $taskStopDeadline)
            } else {
                $taskWorkerNow = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $taskWorker.ProcessId) -ErrorAction SilentlyContinue
            }

            if ($taskWorkerNow -and $taskWorkerNow.ParentProcessId -eq $taskUiProcess.ProcessId -and $taskWorkerNow.CommandLine -and $taskWorkerNow.CommandLine.Contains($taskCliTarget)) {
                Stop-Process -Id $taskWorker.ProcessId -Force -ErrorAction SilentlyContinue
            }
            if ($taskStopFile -and (Test-Path -LiteralPath $taskStopFile)) { Remove-Item -LiteralPath $taskStopFile -Force -ErrorAction SilentlyContinue }
        }
    }

    if ($PSCmdlet.ShouldProcess(('Gemini add-on UI PID ' + $taskUiProcess.ProcessId), 'Close the add-on UI')) {
        Stop-Process -Id $taskUiProcess.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

foreach ($taskValueName in @($taskStartupName)) {
    if (Test-Path -LiteralPath $taskRunKey) {
        if ($PSCmdlet.ShouldProcess(($taskRunKey + '\' + $taskValueName), 'Remove the add-on sign-in startup entry')) {
            Remove-ItemProperty -LiteralPath $taskRunKey -Name $taskValueName -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path -LiteralPath $taskStartupApprovedRunKey) {
        if ($PSCmdlet.ShouldProcess(($taskStartupApprovedRunKey + '\' + $taskValueName), 'Remove the add-on startup approval')) {
            Remove-ItemProperty -LiteralPath $taskStartupApprovedRunKey -Name $taskValueName -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path -LiteralPath $taskStartupApprovedFolderKey) {
        if ($PSCmdlet.ShouldProcess(($taskStartupApprovedFolderKey + '\' + $taskStartupName + '.lnk'), 'Remove the add-on startup-folder approval')) {
            Remove-ItemProperty -LiteralPath $taskStartupApprovedFolderKey -Name ($taskStartupName + '.lnk') -ErrorAction SilentlyContinue
        }
    }
}

foreach ($taskShortcut in $taskShortcutPaths) {
    if (Test-Path -LiteralPath $taskShortcut) {
        if ($PSCmdlet.ShouldProcess($taskShortcut, 'Remove an add-on shortcut')) {
            Remove-Item -LiteralPath $taskShortcut -Force -ErrorAction SilentlyContinue
        }
    }
}

if (Test-Path -LiteralPath $taskUninstallKey) {
    if ($PSCmdlet.ShouldProcess($taskUninstallKey, 'Remove the Installed apps registration')) {
        Remove-Item -LiteralPath $taskUninstallKey -Recurse -Force
    }
}

if (Test-Path -LiteralPath $taskInstallRoot) {
    if ($PSCmdlet.ShouldProcess($taskInstallRoot, 'Remove the add-on program files')) {
        $taskCleanupScript = "Start-Sleep -Seconds 3; `$p = [IO.Path]::GetFullPath('$($taskInstallRoot.Replace("'", "''"))'); if (Test-Path -LiteralPath `$p) { Remove-Item -LiteralPath `$p -Recurse -Force -ErrorAction SilentlyContinue }"
        $taskEncodedCleanup = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($taskCleanupScript))
        Start-Process -FilePath $taskPowerShell -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-EncodedCommand', $taskEncodedCleanup) -WindowStyle Hidden | Out-Null
    }
}

if ($WhatIfPreference) {
    Write-Output 'WhatIf only: no processes, registry entries, shortcuts, or files were changed.'
} else {
    Write-Output 'Gemini Usage Monitor removed. Gemini account and usage data were kept.'
}
